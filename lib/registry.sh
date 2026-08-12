#!/bin/sh
# Registry for generic Git worktrees whose directories may be deleted by an
# external lifecycle manager before workspace can run its archive command.

workspace_registry_root() {
  [ -n "${WORKSPACE_GIT_COMMON_DIR:-}" ] || return 1
  printf '%s/workspace/registry\n' "$WORKSPACE_GIT_COMMON_DIR"
}

workspace_registry_entry() {
  _registry_root=$(workspace_registry_root) || return 1
  validate_workspace_identity "$WORKSPACE_NAME" "workspace registry identity" || return 1
  case "$WORKSPACE_NAME" in
    *[!a-zA-Z0-9_-]*)
      _registry_key=$(printf '%s' "$WORKSPACE_NAME" | git hash-object --stdin 2>/dev/null) || return 1
      _registry_key="identity-$_registry_key"
      ;;
    *) _registry_key="$WORKSPACE_NAME" ;;
  esac
  printf '%s/%s.record\n' "$_registry_root" "$_registry_key"
}

workspace_registry_lock() {
  [ -n "${WORKSPACE_GIT_COMMON_DIR:-}" ] || return 1
  printf '%s/workspace/prune.lock\n' "$WORKSPACE_GIT_COMMON_DIR"
}

acquire_workspace_registry_lock() {
  _workspace_lock=$(workspace_registry_lock) || return 1
  mkdir -p "$(dirname "$_workspace_lock")"

  # Locks from workspace versions before the atomic-symlink format remain
  # valid while their owner is alive. Recover dead legacy locks in place so an
  # upgrade cannot strand an existing installation.
  if [ -d "$_workspace_lock" ] && [ ! -L "$_workspace_lock" ]; then
    _workspace_lock_owner=$(cat "$_workspace_lock/pid" 2>/dev/null || true)
    case "$_workspace_lock_owner" in
      ""|*[!0-9]*)
        # An old process may briefly own the directory before publishing its
        # pid. Preserve that grace window, but do not let an interrupted
        # upgrade leave an unreadable lock forever.
        if ! find "$_workspace_lock" -prune -mmin +1 2>/dev/null | grep -q .; then
          return 1
        fi
        ;;
      *) kill -0 "$_workspace_lock_owner" 2>/dev/null && return 1 ;;
    esac
    rm -f "$_workspace_lock/pid"
    rmdir "$_workspace_lock" 2>/dev/null || return 1
    ln -s "$$" "$_workspace_lock" 2>/dev/null
    return
  fi

  # A symlink publishes owner identity atomically, unlike mkdir followed by a
  # separate pid-file write. Only one process can create this path.
  if ln -s "$$" "$_workspace_lock" 2>/dev/null; then
    return 0
  fi

  _workspace_lock_owner=$(readlink "$_workspace_lock" 2>/dev/null || true)
  case "$_workspace_lock_owner" in
    ""|*[!0-9]*) return 1 ;;
    *) kill -0 "$_workspace_lock_owner" 2>/dev/null && return 1 ;;
  esac

  # Serialize stale-owner removal so two waiters cannot remove a replacement
  # lock. An abandoned reaper is recoverable after one minute.
  _workspace_lock_reaper="$_workspace_lock.reaper"
  if ! mkdir "$_workspace_lock_reaper" 2>/dev/null; then
    if find "$_workspace_lock_reaper" -prune -mmin +1 2>/dev/null | grep -q .; then
      rmdir "$_workspace_lock_reaper" 2>/dev/null || true
    fi
    return 1
  fi
  if [ "$(readlink "$_workspace_lock" 2>/dev/null || true)" = "$_workspace_lock_owner" ]; then
    rm -f "$_workspace_lock"
  fi
  rmdir "$_workspace_lock_reaper" 2>/dev/null || true
  ln -s "$$" "$_workspace_lock" 2>/dev/null
}

release_workspace_registry_lock() {
  _workspace_lock=$(workspace_registry_lock) || return 0
  [ "$(readlink "$_workspace_lock" 2>/dev/null || true)" = "$$" ] || return 0
  rm -f "$_workspace_lock"
}

workspace_registry_lock_owned() {
  _workspace_lock=$(workspace_registry_lock) || return 1
  [ "$(readlink "$_workspace_lock" 2>/dev/null || true)" = "$$" ]
}

wait_for_workspace_registry_lock() {
  _registry_lock_attempt=0
  _registry_lock_attempts="${WORKSPACE_REGISTRY_LOCK_ATTEMPTS:-0}"
  until acquire_workspace_registry_lock; do
    _registry_lock_attempt=$((_registry_lock_attempt + 1))
    if [ "$_registry_lock_attempts" -gt 0 ] && \
      [ "$_registry_lock_attempt" -ge "$_registry_lock_attempts" ]; then
      return 1
    fi
    sleep 0.1
  done
}

registered_workspace_port() {
  _registered_entry=$(workspace_registry_entry) || return 1
  [ -f "$_registered_entry" ] && [ ! -L "$_registered_entry" ] || return 1
  [ "$(sed -n '1p' "$_registered_entry")" = "$WORKSPACE_NAME" ] || return 1
  _registered_value=$(sed -n '4p' "$_registered_entry")
  case "$_registered_value" in
    ""|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$_registered_value" ;;
  esac
}

select_available_workspace_port() {
  _registry_root=$(workspace_registry_root) || return 1
  _registry_entry=$(workspace_registry_entry) || return 1
  _selected_port=$(validate_workspace_port_block "$1") || return 1
  _proposed_port="$_selected_port"

  while :; do
    _port_conflict=0
    for _other_record in "$_registry_root"/*.record; do
      [ -f "$_other_record" ] && [ ! -L "$_other_record" ] || continue
      [ "$_other_record" = "$_registry_entry" ] && continue
      _other_port=$(sed -n '4p' "$_other_record")
      case "$_other_port" in
        ""|*[!0-9]*) continue ;;
      esac
      _other_port=$(printf '%s' "$_other_port" | sed 's/^0*//')
      [ -n "$_other_port" ] || continue
      [ "${#_other_port}" -le 5 ] || continue
      if [ "$_selected_port" -le "$((_other_port + 9))" ] && \
        [ "$_other_port" -le "$((_selected_port + 9))" ]; then
        _port_conflict=1
        break
      fi
    done
    [ "$_port_conflict" -eq 1 ] || break
    [ -z "${WORKSPACE_PORT:-}" ] || return 1
    _selected_port=$((_selected_port + 10))
    [ "$_selected_port" -le 58990 ] || _selected_port=50000
    [ "$_selected_port" != "$_proposed_port" ] || return 1
  done

  printf '%s\n' "$_selected_port"
}

register_workspace() {
  [ "${WORKSPACE_PROVIDER:-}" = "git" ] || return 0
  _registry_root=$(workspace_registry_root) || return 1
  _registry_entry=$(workspace_registry_entry) || return 1
  _registered_port="${1:-}"
  if [ -n "$_registered_port" ]; then
    _registered_port=$(validate_workspace_port_block "$_registered_port") || return 1
  fi
  _registered_worktree=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
  _registry_temp="$_registry_root/.record.$$"

  mkdir -p "$_registry_root"
  _registry_lock_was_owned=0
  if workspace_registry_lock_owned; then
    _registry_lock_was_owned=1
  else
    wait_for_workspace_registry_lock || return 1
  fi

  if [ -n "$_registered_port" ]; then
    if ! _registered_port=$(select_available_workspace_port "$_registered_port"); then
      [ "$_registry_lock_was_owned" -eq 1 ] || release_workspace_registry_lock
      return 1
    fi
  fi

  {
    printf '%s\n' "$WORKSPACE_NAME"
    printf '%s\n' "$WORKSPACE_ROOT_PATH"
    printf '%s\n' "$_registered_worktree"
    printf '%s\n' "$_registered_port"
  } > "$_registry_temp"
  mv "$_registry_temp" "$_registry_entry"
  [ "$_registry_lock_was_owned" -eq 1 ] || release_workspace_registry_lock
}

unregister_workspace() {
  [ "${WORKSPACE_PROVIDER:-}" = "git" ] || return 0
  if [ -n "${1:-}" ]; then
    _registry_root=$(workspace_registry_root) || return 1
    case "$1" in
      "$_registry_root"/*.record|"$_registry_root"/*.record.pruning.*) _registry_entry="$1" ;;
      *) return 1 ;;
    esac
  else
    _registry_entry=$(workspace_registry_entry) || return 1
  fi
  rm -f "$_registry_entry"
}

load_registered_workspace() {
  _loaded_registry_entry="$1"
  [ -f "$_loaded_registry_entry" ] && [ ! -L "$_loaded_registry_entry" ] || return 1

  WORKSPACE_NAME=$(sed -n '1p' "$_loaded_registry_entry")
  WORKSPACE_ROOT_PATH=$(sed -n '2p' "$_loaded_registry_entry")
  WORKSPACE_REGISTERED_PATH=$(sed -n '3p' "$_loaded_registry_entry")
  WORKSPACE_REGISTERED_PORT=$(sed -n '4p' "$_loaded_registry_entry")
  WORKSPACE_PROVIDER="git"
  WORKSPACE_GIT_COMMON_DIR=$(dirname "$(dirname "$(dirname "$_loaded_registry_entry")")")

  validate_workspace_identity "$WORKSPACE_NAME" "workspace registry identity" || return 1
  [ -d "$WORKSPACE_ROOT_PATH" ] || return 1
  [ -n "$WORKSPACE_REGISTERED_PATH" ] || return 1
  case "$WORKSPACE_REGISTERED_PORT" in
    ""|*[!0-9]*) return 1 ;;
  esac
}
