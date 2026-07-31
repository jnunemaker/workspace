#!/bin/sh
# Registry for generic Git worktrees whose directories may be deleted by an
# external lifecycle manager before workspace can run its archive command.

workspace_registry_root() {
  [ -n "${WORKSPACE_GIT_COMMON_DIR:-}" ] || return 1
  printf '%s/workspace/registry\n' "$WORKSPACE_GIT_COMMON_DIR"
}

workspace_registry_entry() {
  _registry_root=$(workspace_registry_root) || return 1
  case "$WORKSPACE_NAME" in
    ""|*[!a-zA-Z0-9_-]*) return 1 ;;
  esac
  printf '%s/%s.record\n' "$_registry_root" "$WORKSPACE_NAME"
}

workspace_registry_lock() {
  [ -n "${WORKSPACE_GIT_COMMON_DIR:-}" ] || return 1
  printf '%s/workspace/prune.lock\n' "$WORKSPACE_GIT_COMMON_DIR"
}

acquire_workspace_registry_lock() {
  _workspace_lock=$(workspace_registry_lock) || return 1
  if ! mkdir "$_workspace_lock" 2>/dev/null; then
    _workspace_lock_owner=$(cat "$_workspace_lock/pid" 2>/dev/null || true)
    case "$_workspace_lock_owner" in
      ""|*[!0-9]*) ;;
      *) kill -0 "$_workspace_lock_owner" 2>/dev/null && return 1 ;;
    esac
    rm -f "$_workspace_lock/pid"
    rmdir "$_workspace_lock" 2>/dev/null || return 1
    mkdir "$_workspace_lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$_workspace_lock/pid"
}

release_workspace_registry_lock() {
  _workspace_lock=$(workspace_registry_lock) || return 0
  [ "$(cat "$_workspace_lock/pid" 2>/dev/null || true)" = "$$" ] || return 0
  rm -f "$_workspace_lock/pid"
  rmdir "$_workspace_lock" 2>/dev/null || true
}

workspace_registry_lock_owned() {
  _workspace_lock=$(workspace_registry_lock) || return 1
  [ "$(cat "$_workspace_lock/pid" 2>/dev/null || true)" = "$$" ]
}

wait_for_workspace_registry_lock() {
  _registry_lock_attempt=0
  _registry_lock_attempts="${WORKSPACE_REGISTRY_LOCK_ATTEMPTS:-100}"
  until acquire_workspace_registry_lock; do
    _registry_lock_attempt=$((_registry_lock_attempt + 1))
    [ "$_registry_lock_attempt" -lt "$_registry_lock_attempts" ] || return 1
    sleep 0.1
  done
}

register_workspace() {
  [ "${WORKSPACE_PROVIDER:-}" = "git" ] || return 0
  _registry_root=$(workspace_registry_root) || return 0
  _registry_entry=$(workspace_registry_entry) || return 0
  _registered_port="${1:-}"
  _registered_worktree=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
  _registry_temp="$_registry_root/.record.$$"

  mkdir -p "$_registry_root"
  _registry_lock_was_owned=0
  if workspace_registry_lock_owned; then
    _registry_lock_was_owned=1
  else
    wait_for_workspace_registry_lock || return 1
  fi

  case "$_registered_port" in
    ""|*[!0-9]*) ;;
    *)
      _proposed_port="$_registered_port"
      while :; do
        _port_conflict=0
        for _other_record in "$_registry_root"/*.record; do
          [ -f "$_other_record" ] || continue
          [ "$_other_record" = "$_registry_entry" ] && continue
          if [ "$(sed -n '4p' "$_other_record")" = "$_registered_port" ]; then
            _port_conflict=1
            break
          fi
        done
        [ "$_port_conflict" -eq 1 ] || break
        _registered_port=$((_registered_port + 10))
        [ "$_registered_port" -le 58990 ] || _registered_port=50000
        if [ "$_registered_port" = "$_proposed_port" ]; then
          [ "$_registry_lock_was_owned" -eq 1 ] || release_workspace_registry_lock
          return 1
        fi
      done
      ;;
  esac

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
    _registry_entry=$(workspace_registry_entry) || return 0
  fi
  rm -f "$_registry_entry"
}

load_registered_workspace() {
  _loaded_registry_entry="$1"
  [ -f "$_loaded_registry_entry" ] || return 1

  WORKSPACE_NAME=$(sed -n '1p' "$_loaded_registry_entry")
  WORKSPACE_ROOT_PATH=$(sed -n '2p' "$_loaded_registry_entry")
  WORKSPACE_REGISTERED_PORT=$(sed -n '4p' "$_loaded_registry_entry")
  WORKSPACE_PROVIDER="git"
  WORKSPACE_GIT_COMMON_DIR=$(dirname "$(dirname "$(dirname "$_loaded_registry_entry")")")

  case "$WORKSPACE_NAME" in
    ""|*[!a-zA-Z0-9_-]*) return 1 ;;
  esac
  [ -d "$WORKSPACE_ROOT_PATH" ] || return 1
}
