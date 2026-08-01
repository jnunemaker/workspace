#!/bin/sh
# Shared functions for the workspace CLI.
# Sourced by all subcommands.

# ── Output helpers ──────────────────────────────────────────────────

_dim="\033[2m"; _reset="\033[0m"; _bold="\033[1m"
_green="\033[32m"; _yellow="\033[33m"

header()  { printf "\n${_bold}%s${_reset}\n" "$1"; }
step()    { printf "  %s\n" "$1"; }
detail()  { printf "  %s\n" "$1"; }
ok()      { printf "${_green}  ✓${_reset} %s\n" "$1"; }
warn()    { printf "${_yellow}  !${_reset} %s\n" "$1"; }
err()     { printf "  error: %s\n" "$1" >&2; }
divider() { printf "\n${_dim}────────────────────────────────────────${_reset}\n\n"; }

# ── Workspace name resolution ──────────────────────────────────────

resolve_workspace() {
  WORKSPACE_PROVIDER=""
  WORKSPACE_GIT_COMMON_DIR=""
  WORKSPACE_GIT_ROOT_PATH=""
  WORKSPACE_ROOT_PATH="${SUPERCONDUCTOR_ROOT_PATH:-${SUPERSET_ROOT_PATH:-$CONDUCTOR_ROOT_PATH}}"
  WORKSPACE_NAME="${SUPERCONDUCTOR_WORKSPACE_NAME:-${SUPERSET_WORKSPACE_NAME:-$CONDUCTOR_WORKSPACE_NAME}}"

  if [ -n "${SUPERCONDUCTOR_ROOT_PATH:-}${SUPERCONDUCTOR_WORKSPACE_NAME:-}" ]; then
    WORKSPACE_PROVIDER="superconductor"
  elif [ -n "${SUPERSET_ROOT_PATH:-}${SUPERSET_WORKSPACE_NAME:-}" ]; then
    WORKSPACE_PROVIDER="superset"
  elif [ -n "${CONDUCTOR_ROOT_PATH:-}${CONDUCTOR_WORKSPACE_NAME:-}" ]; then
    WORKSPACE_PROVIDER="conductor"
  fi

  # "default" is superset's name for the main branch — treat as no workspace
  if [ "$WORKSPACE_NAME" = "default" ]; then
    WORKSPACE_NAME=""
  fi

  # Existing integrations always win. Codex doesn't currently provide
  # worktree path variables, so fall back to Git only when none are present.
  if [ -n "$WORKSPACE_PROVIDER" ]; then
    return
  fi

  detect_git_workspace
}

# Canonicalize a path returned by git rev-parse without requiring newer Git's
# --path-format flag.
canonical_git_path() {
  _git_path="$1"
  [ -n "$_git_path" ] || return 1
  case "$_git_path" in
    /*) ;;
    *) _git_path="$(pwd)/$_git_path" ;;
  esac

  if [ -d "$_git_path" ]; then
    (cd "$_git_path" 2>/dev/null && pwd -P)
    return
  fi

  _git_path_dir=$(dirname "$_git_path")
  _git_path_base=$(basename "$_git_path")
  if _git_path_dir=$(cd "$_git_path_dir" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "$_git_path_dir" "$_git_path_base"
  fi
}

# Detect a Codex-managed linked Git worktree. The main checkout and worktrees
# created elsewhere retain their existing default-workspace behavior.
detect_git_workspace() {
  _git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
  _git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
  [ -n "$_git_dir" ] && [ -n "$_git_common_dir" ] || return 0

  _git_dir=$(canonical_git_path "$_git_dir")
  _git_common_dir=$(canonical_git_path "$_git_common_dir")
  [ -n "$_git_dir" ] && [ -n "$_git_common_dir" ] || return 0

  WORKSPACE_GIT_COMMON_DIR="$_git_common_dir"
  _git_root_path=$(git config --path --get core.worktree 2>/dev/null || true)
  if [ -n "$_git_root_path" ]; then
    case "$_git_root_path" in
      /*) ;;
      *) _git_root_path="$_git_common_dir/$_git_root_path" ;;
    esac
  else
    _git_root_path=$(git worktree list --porcelain 2>/dev/null \
      | sed -n 's/^worktree //p' \
      | head -1)
  fi
  WORKSPACE_GIT_ROOT_PATH=$(canonical_git_path "$_git_root_path")
  [ -n "$WORKSPACE_GIT_ROOT_PATH" ] || return 0

  [ "$_git_dir" != "$_git_common_dir" ] || return 0
  case "$_git_dir" in
    "$_git_common_dir"/worktrees/*) ;;
    *) return 0 ;;
  esac

  _codex_home="${CODEX_HOME:-${HOME:-}/.codex}"
  _codex_worktrees=$(canonical_git_path "$_codex_home/worktrees")
  _git_worktree_path=$(git rev-parse --show-toplevel 2>/dev/null || true)
  _git_worktree_path=$(canonical_git_path "$_git_worktree_path")
  [ -n "$_codex_worktrees" ] && [ -n "$_git_worktree_path" ] || return 0
  case "$_git_worktree_path" in
    "$_codex_worktrees"/*) ;;
    *) return 0 ;;
  esac

  WORKSPACE_PROVIDER="git"
  WORKSPACE_ROOT_PATH="$WORKSPACE_GIT_ROOT_PATH"
  WORKSPACE_NAME=$(basename "$_git_dir")
}

# Returns true if this is the "default" / main branch workspace (no isolation needed)
is_default_workspace() {
  [ -z "$WORKSPACE_NAME" ]
}

# ── Workspace name sanitization ────────────────────────────────────

# Sanitizes a workspace name for safe use in database names and file paths.
# Applied to Superset-family and generic Git worktrees; Conductor retains its
# historical branch-name behavior.
# Sets: WORKSPACE_NAME (overwritten with sanitized value)
sanitize_workspace_name() {
  _raw_name="${SUPERCONDUCTOR_WORKSPACE_NAME:-$SUPERSET_WORKSPACE_NAME}"
  if [ "$WORKSPACE_PROVIDER" = "git" ]; then
    _raw_name="$WORKSPACE_NAME"
  fi
  if [ -n "$_raw_name" ] && [ "$_raw_name" != "default" ]; then
    WORKSPACE_NAME=$(printf '%s' "$_raw_name" \
      | tr -cs 'a-zA-Z0-9_-' '-' \
      | sed 's/--*/-/g; s/^-//; s/-$//' \
      | cut -c1-40 \
      | sed 's/-$//')
  fi
}

# Print the base port for the current provider. Existing provider semantics are
# preserved: Conductor still relies on CONDUCTOR_PORT, while Superset-family
# and Git worktrees derive deterministic 10-port blocks from their names.
derive_workspace_port() {
  _default_port="$1"
  _port_name="${SUPERCONDUCTOR_WORKSPACE_NAME:-$SUPERSET_WORKSPACE_NAME}"
  if [ -z "$_port_name" ] && [ "$WORKSPACE_PROVIDER" = "git" ]; then
    if command -v registered_workspace_port >/dev/null 2>&1; then
      _registered_port=$(registered_workspace_port 2>/dev/null || true)
      if [ -n "$_registered_port" ]; then
        printf '%s\n' "$_registered_port"
        return
      fi
    fi
    _port_name="$WORKSPACE_NAME"
  fi

  if [ -n "${CONDUCTOR_PORT:-}" ]; then
    printf '%s\n' "$CONDUCTOR_PORT"
  elif [ -n "$_port_name" ] && \
    { [ "$_port_name" != "default" ] || [ "$WORKSPACE_PROVIDER" = "git" ]; }; then
    _port_hash=$(printf '%s' "$_port_name" | cksum | awk '{print $1}')
    printf '%s\n' "$(( ((_port_hash % 900) * 10) + 50000 ))"
  else
    printf '%s\n' "$_default_port"
  fi
}

# ── App name detection ─────────────────────────────────────────────

# Detects the app name from the directory name, normalized for database use.
# Sets: APP_NAME
detect_app_name() {
  APP_NAME=$(basename "$(pwd)" | tr '-' '_')
}
