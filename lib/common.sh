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
  WORKSPACE_INVALID_NAME=""
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

  # Existing integrations always win. Fall back to Git's own linked-worktree
  # metadata when a manager does not provide identity or root variables.
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

# Detect any linked Git worktree. The main checkout remains the default
# workspace because its Git directory and common directory are the same.
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

  WORKSPACE_PROVIDER="git"
  WORKSPACE_ROOT_PATH="$WORKSPACE_GIT_ROOT_PATH"
  WORKSPACE_NAME=$(basename "$_git_dir")
}

# Returns true if this is the "default" / main branch workspace (no isolation needed)
is_default_workspace() {
  [ -z "$WORKSPACE_NAME" ]
}

# ── Stable workspace identity ────────────────────────────────────

# Provider names are discovery defaults, not durable database identities.
# Existing projects may already pin the suffix in .conductor-workspace, while
# Workspace pins its selected identity in .workspace after bootstrap. Projects
# with another established scheme can provide bin/workspace-identity-hook.
# Precedence is legacy marker, Workspace marker, identity hook, then provider
# or Git-derived default.
validate_workspace_identity() {
  _identity_value="$1"
  _identity_source="$2"

  if [ -z "$_identity_value" ]; then
    err "$_identity_source is empty"
    return 1
  fi
  if [ "$_identity_value" = "default" ]; then
    err "$_identity_source contains the reserved workspace name 'default'"
    return 1
  fi
  if [ "$(printf '%s' "$_identity_value" | awk 'END { print NR }')" -gt 1 ]; then
    err "$_identity_source must contain exactly one workspace name"
    return 1
  fi
  case "$_identity_value" in
    *"$(printf '\r')"*) err "$_identity_source contains an invalid carriage return"; return 1 ;;
  esac
}

read_workspace_identity_file() {
  _identity_file="$1"
  _identity_label="$2"
  [ -f "$_identity_file" ] || return 1
  [ -s "$_identity_file" ] || {
    err "$_identity_label is empty"
    return 2
  }
  _identity_result=$(cat "$_identity_file")
  validate_workspace_identity "$_identity_result" "$_identity_label" || return 2
}

resolve_workspace_identity() {
  _derived_workspace_name="$WORKSPACE_NAME"
  WORKSPACE_IDENTITY_SOURCE="derived"

  # Bootstrap must be able to replace the stable marker atomically. Reject a
  # directory, symlink, or other non-regular node before setup or database work
  # begins instead of discovering it only when the final rename runs.
  if [ -L .workspace ] || { [ -e .workspace ] && [ ! -f .workspace ]; }; then
    err "Refusing to use non-regular workspace identity: .workspace"
    return 1
  fi
  if [ -e .conductor-workspace ] && [ ! -f .conductor-workspace ]; then
    err "Refusing to use non-regular workspace identity: .conductor-workspace"
    return 1
  fi

  # An empty legacy marker historically meant "not pinned yet," so it may
  # defer to Workspace. An empty .workspace is corruption and fails closed.
  if [ -s .conductor-workspace ]; then
    read_workspace_identity_file .conductor-workspace .conductor-workspace || return 1
    WORKSPACE_NAME="$_identity_result"
    WORKSPACE_IDENTITY_SOURCE=".conductor-workspace"
  elif [ -f .workspace ]; then
    read_workspace_identity_file .workspace .workspace || return 1
    WORKSPACE_NAME="$_identity_result"
    WORKSPACE_IDENTITY_SOURCE=".workspace"
  elif [ -x bin/workspace-identity-hook ]; then
    export WORKSPACE_PROVIDER WORKSPACE_ROOT_PATH WORKSPACE_NAME
    if ! _hook_workspace_name=$(bin/workspace-identity-hook); then
      err "bin/workspace-identity-hook failed"
      return 1
    fi
    if [ -n "$_hook_workspace_name" ]; then
      validate_workspace_identity "$_hook_workspace_name" "bin/workspace-identity-hook output" || return 1
      WORKSPACE_NAME="$_hook_workspace_name"
      WORKSPACE_IDENTITY_SOURCE="bin/workspace-identity-hook"
    fi
  fi

  if [ -n "$_derived_workspace_name" ] && \
    [ "$WORKSPACE_NAME" != "$_derived_workspace_name" ]; then
    warn "Workspace name drift: provider=\"$_derived_workspace_name\", ${WORKSPACE_IDENTITY_SOURCE}=\"$WORKSPACE_NAME\" — using the stable identity."
  fi
  if [ "$WORKSPACE_IDENTITY_SOURCE" != "derived" ]; then
    WORKSPACE_INVALID_NAME=""
  fi
}

write_workspace_identity() {
  validate_workspace_identity "$WORKSPACE_NAME" "workspace identity" || return 1
  if [ -L .workspace ] || { [ -e .workspace ] && [ ! -f .workspace ]; }; then
    err "Refusing to replace non-regular workspace identity: .workspace"
    return 1
  fi
  if [ -f .workspace ] && [ ! -L .workspace ] && \
    [ "$(cat .workspace)" = "$WORKSPACE_NAME" ]; then
    return 0
  fi
  _identity_temporary=$(mktemp "./.workspace.XXXXXX") || return 1
  if ! printf '%s' "$WORKSPACE_NAME" > "$_identity_temporary" || \
    ! mv "$_identity_temporary" .workspace; then
    rm -f "$_identity_temporary"
    return 1
  fi
}

# ── Workspace name sanitization ────────────────────────────────────

# Sanitizes a workspace name for safe use in database names and file paths.
# Superset retains its historical 45-character database identity. Newer
# Superconductor and generic Git identities use the 40-character default, while
# Conductor retains its historical branch-name behavior.
# Sets: WORKSPACE_NAME (overwritten with sanitized value)
sanitize_workspace_name() {
  WORKSPACE_INVALID_NAME=""
  _workspace_name_limit=40
  if [ "$WORKSPACE_PROVIDER" = "git" ]; then
    _raw_name="$WORKSPACE_NAME"
  elif [ -n "${SUPERCONDUCTOR_WORKSPACE_NAME:-}" ]; then
    _raw_name="$SUPERCONDUCTOR_WORKSPACE_NAME"
  elif [ -n "${SUPERSET_WORKSPACE_NAME:-}" ]; then
    _raw_name="$SUPERSET_WORKSPACE_NAME"
    _workspace_name_limit=45
  else
    _raw_name=""
  fi
  if [ -n "$_raw_name" ] && [ "$_raw_name" != "default" ]; then
    WORKSPACE_NAME=$(printf '%s' "$_raw_name" \
      | tr -cs 'a-zA-Z0-9_-' '-' \
      | sed 's/--*/-/g; s/^-//; s/-$//' \
      | cut -c1-"$_workspace_name_limit" \
      | sed 's/-$//')
    [ -n "$WORKSPACE_NAME" ] || WORKSPACE_INVALID_NAME=1
  fi
}

# Import a dotenv file as defaults. Values already exported by the caller or
# workspace manager are restored afterward, so the file cannot replace them.
# Hooks sourced later may still deliberately override any value.
load_dotenv_defaults() {
  local _dotenv_file _dotenv_existing_exports _dotenv_status

  _dotenv_file="${1:-.env}"
  [ -f "$_dotenv_file" ] || return 0

  _dotenv_existing_exports=$(export -p)
  set -a
  . "$_dotenv_file"
  _dotenv_status=$?
  set +a
  [ "$_dotenv_status" -eq 0 ] || return "$_dotenv_status"
  eval "$_dotenv_existing_exports"
}

# Print the base port for the current provider. Manager-assigned ports win;
# otherwise named worktrees receive deterministic 10-port blocks.
derive_workspace_port() {
  _default_port="$1"
  _provider_port="${SUPERCONDUCTOR_PORT:-${SUPERSET_PORT:-${CONDUCTOR_PORT:-}}}"
  _port_name="${WORKSPACE_NAME:-${SUPERCONDUCTOR_WORKSPACE_NAME:-${SUPERSET_WORKSPACE_NAME:-${CONDUCTOR_WORKSPACE_NAME:-}}}}"
  if [ "$WORKSPACE_PROVIDER" = "git" ]; then
    if command -v registered_workspace_port >/dev/null 2>&1; then
      _registered_port=$(registered_workspace_port 2>/dev/null || true)
      if [ -n "$_registered_port" ]; then
        printf '%s\n' "$_registered_port"
        return
      fi
    fi
  fi

  if [ -n "${WORKSPACE_PORT:-}" ]; then
    printf '%s\n' "$WORKSPACE_PORT"
  elif [ -n "$_provider_port" ]; then
    printf '%s\n' "$_provider_port"
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
