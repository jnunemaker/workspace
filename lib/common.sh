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
  local _manager _owner _root _name _port _checkout
  WORKSPACE_PROVIDER=""
  WORKSPACE_INVALID_NAME=""
  WORKSPACE_GIT_COMMON_DIR=""
  WORKSPACE_GIT_ROOT_PATH=""
  WORKSPACE_ROOT_PATH=""
  WORKSPACE_NAME=""
  _checkout=$(git rev-parse --show-toplevel 2>/dev/null || true)
  _checkout=$(canonical_git_path "$_checkout") || _checkout=""

  # Manager variables can be inherited by shells in other worktrees. Validate
  # every family before using any of its identity, shared files, or ports.
  for _manager in SUPERCONDUCTOR SUPERSET CONDUCTOR; do
    eval '_owner=${'"${_manager}"'_WORKSPACE_PATH:-}'
    eval '_root=${'"${_manager}"'_ROOT_PATH:-}'
    eval '_name=${'"${_manager}"'_WORKSPACE_NAME:-}'
    # SUPERSET_PORT is Superset's notification port, not a workspace port.
    _port=""
    [ "$_manager" = SUPERSET ] || eval '_port=${'"${_manager}"'_PORT:-}'
    [ -n "$_root$_name$_port" ] || continue
    if [ -n "$_owner" ] && [ -d "$_owner" ]; then
      _owner=$(canonical_git_path "$_owner") || _owner=""
    else
      _owner=""
    fi
    if [ -z "$_owner" ] || [ -z "$_checkout" ]; then
      err "${_manager}_WORKSPACE_PATH must identify an existing checkout directory; cannot verify manager ownership against the current Git top-level. Relaunch from the manager or use a clean shell without that manager's environment."
      return 1
    fi
    if [ "$_owner" != "$_checkout" ]; then
      unset "${_manager}_ROOT_PATH" "${_manager}_WORKSPACE_NAME" \
        "${_manager}_WORKSPACE_PATH"
      [ "$_manager" = SUPERSET ] || unset "${_manager}_PORT"
      continue
    fi
    # A port alone is not an identity: retain Git isolation and registration.
    [ -n "$_root$_name" ] || continue
    if [ -z "$WORKSPACE_PROVIDER" ]; then
      WORKSPACE_PROVIDER=$(printf '%s' "$_manager" | tr '[:upper:]' '[:lower:]')
      WORKSPACE_ROOT_PATH="$_root"
      WORKSPACE_NAME="$_name"
    fi
  done

  # "default" is superset's name for the main branch — treat as no workspace
  if [ "$WORKSPACE_NAME" = "default" ]; then
    WORKSPACE_NAME=""
  fi

  # A verified integration wins. Otherwise use this checkout's Git metadata.
  if [ -n "$WORKSPACE_PROVIDER" ]; then
    return
  fi

  detect_git_workspace
}

# Snapshot even unexported manager inputs so sourced project files cannot
# introduce an unverified family (or resurrect a rejected inherited family).
manager_environment() (
  for _manager in SUPERCONDUCTOR SUPERSET CONDUCTOR; do
    for _field in ROOT_PATH WORKSPACE_NAME WORKSPACE_PATH PORT; do
      _variable="${_manager}_${_field}"
      eval '[ "${'"$_variable"'+x}" ]' && export "$_variable"
    done
  done
  export -p | grep -E ' (SUPERCONDUCTOR|SUPERSET|CONDUCTOR)_(ROOT_PATH|WORKSPACE_NAME|WORKSPACE_PATH|PORT)=' || true
)

clear_manager_environment() {
  unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH SUPERCONDUCTOR_PORT
  unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME SUPERSET_WORKSPACE_PATH SUPERSET_PORT
  unset CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME CONDUCTOR_WORKSPACE_PATH CONDUCTOR_PORT
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
  if printf '%s' "$_identity_value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    err "$_identity_source contains an invalid control character"
    return 1
  fi
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

  # Provider and Git discovery decide whether this is the root checkout. A
  # stable marker or adoption hook must never turn that default checkout into
  # an isolated workspace after discovery has selected the root path.
  if is_default_workspace && [ -z "${WORKSPACE_INVALID_NAME:-}" ]; then
    return 0
  fi

  # Bootstrap must be able to replace the stable marker atomically. Reject a
  # directory, symlink, or other non-regular node before setup or database work
  # begins instead of discovering it only when the final rename runs.
  if [ -L .workspace ] || { [ -e .workspace ] && [ ! -f .workspace ]; }; then
    err "Refusing to use non-regular workspace identity: .workspace"
    return 1
  fi
  if [ -L .conductor-workspace ] || { [ -e .conductor-workspace ] && [ ! -f .conductor-workspace ]; }; then
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
  elif [ "$WORKSPACE_PROVIDER" = "superconductor" ]; then
    _raw_name="$SUPERCONDUCTOR_WORKSPACE_NAME"
  elif [ "$WORKSPACE_PROVIDER" = "superset" ]; then
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
# Manager inputs stay frozen, including absent/rejected families. Project
# defaults such as WORKSPACE_PORT remain supported.
load_dotenv_defaults() {
  local _dotenv_file _dotenv_existing_exports _dotenv_status
  local _dotenv_manager_environment
  local _dotenv_workspace_name _dotenv_workspace_provider _dotenv_workspace_root_path
  local _dotenv_workspace_git_common_dir _dotenv_workspace_git_root_path
  local _dotenv_workspace_invalid_name _dotenv_workspace_identity_source
  local _dotenv_workspace_port _dotenv_workspace_port_set

  _dotenv_file="${1:-.env}"
  [ -f "$_dotenv_file" ] || return 0

  # These values are resolved lifecycle state, even when they were not
  # exported by the provider. Dotenv may supply app defaults such as ports,
  # but it must not redirect database or cleanup identity after validation.
  _dotenv_workspace_name="$WORKSPACE_NAME"
  _dotenv_workspace_provider="$WORKSPACE_PROVIDER"
  _dotenv_workspace_root_path="$WORKSPACE_ROOT_PATH"
  _dotenv_workspace_git_common_dir="$WORKSPACE_GIT_COMMON_DIR"
  _dotenv_workspace_git_root_path="$WORKSPACE_GIT_ROOT_PATH"
  _dotenv_workspace_invalid_name="${WORKSPACE_INVALID_NAME:-}"
  _dotenv_workspace_identity_source="${WORKSPACE_IDENTITY_SOURCE:-}"
  _dotenv_workspace_port="${WORKSPACE_PORT:-}"
  _dotenv_workspace_port_set="${WORKSPACE_PORT+x}"

  _dotenv_manager_environment=$(manager_environment)
  _dotenv_existing_exports=$(export -p)
  set -a
  . "$_dotenv_file"
  _dotenv_status=$?
  set +a
  eval "$_dotenv_existing_exports"
  clear_manager_environment
  [ -z "$_dotenv_manager_environment" ] || eval "$_dotenv_manager_environment"

  WORKSPACE_NAME="$_dotenv_workspace_name"
  WORKSPACE_PROVIDER="$_dotenv_workspace_provider"
  WORKSPACE_ROOT_PATH="$_dotenv_workspace_root_path"
  WORKSPACE_GIT_COMMON_DIR="$_dotenv_workspace_git_common_dir"
  WORKSPACE_GIT_ROOT_PATH="$_dotenv_workspace_git_root_path"
  WORKSPACE_INVALID_NAME="$_dotenv_workspace_invalid_name"
  WORKSPACE_IDENTITY_SOURCE="$_dotenv_workspace_identity_source"

  # A failed source is not a usable set of defaults. Roll back every port input
  # that can influence lifecycle cleanup instead of retaining partial values.
  if [ "$_dotenv_status" -ne 0 ]; then
    if [ -n "$_dotenv_workspace_port_set" ]; then
      WORKSPACE_PORT="$_dotenv_workspace_port"; export WORKSPACE_PORT
    else
      unset WORKSPACE_PORT
    fi
  fi

  return "$_dotenv_status"
}

# Source project-owned toolchain setup into the current lifecycle shell. This
# deliberately stays runtime-manager agnostic: projects may activate mise,
# asdf, rbenv, Nix, or any other environment by updating PATH and exporting
# variables here. The resolved lifecycle identity is exported first so the
# hook can inspect it without needing provider-specific branching.
source_workspace_environment_hook() {
  local _environment_workspace_provider _environment_workspace_root_path
  local _environment_workspace_name _environment_workspace_git_common_dir
  local _environment_workspace_git_root_path _environment_workspace_invalid_name
  local _environment_workspace_identity_source _environment_workspace_db_suffix
  local _environment_workspace_db_suffix_set
  local _environment_workspace_registered_port _environment_workspace_registered_port_set
  local _environment_provider_exports _environment_hook_status _environment_errexit_set
  local _environment_manager_environment

  [ -f bin/workspace-environment-hook ] || return 0

  _environment_workspace_provider="$WORKSPACE_PROVIDER"
  _environment_workspace_root_path="$WORKSPACE_ROOT_PATH"
  _environment_workspace_name="$WORKSPACE_NAME"
  _environment_workspace_git_common_dir="$WORKSPACE_GIT_COMMON_DIR"
  _environment_workspace_git_root_path="$WORKSPACE_GIT_ROOT_PATH"
  _environment_workspace_invalid_name="${WORKSPACE_INVALID_NAME:-}"
  _environment_workspace_identity_source="${WORKSPACE_IDENTITY_SOURCE:-}"
  _environment_workspace_db_suffix="${WORKSPACE_DB_SUFFIX:-}"
  _environment_workspace_db_suffix_set="${WORKSPACE_DB_SUFFIX+x}"
  _environment_workspace_registered_port="${WORKSPACE_REGISTERED_PORT:-}"
  _environment_workspace_registered_port_set="${WORKSPACE_REGISTERED_PORT+x}"
  _environment_manager_environment=$(manager_environment)
  _environment_provider_exports=$(export -p | grep -E \
    ' WORKSPACE_PORT=' \
    || true)
  case "$-" in
    *e*) _environment_errexit_set=1 ;;
    *) _environment_errexit_set=0 ;;
  esac

  export WORKSPACE_PROVIDER WORKSPACE_ROOT_PATH WORKSPACE_NAME
  if . ./bin/workspace-environment-hook; then
    _environment_hook_status=0
  else
    _environment_hook_status=$?
  fi
  set +e

  WORKSPACE_PROVIDER="$_environment_workspace_provider"
  WORKSPACE_ROOT_PATH="$_environment_workspace_root_path"
  WORKSPACE_NAME="$_environment_workspace_name"
  WORKSPACE_GIT_COMMON_DIR="$_environment_workspace_git_common_dir"
  WORKSPACE_GIT_ROOT_PATH="$_environment_workspace_git_root_path"
  WORKSPACE_INVALID_NAME="$_environment_workspace_invalid_name"
  WORKSPACE_IDENTITY_SOURCE="$_environment_workspace_identity_source"
  export WORKSPACE_PROVIDER WORKSPACE_ROOT_PATH WORKSPACE_NAME
  if [ -n "$_environment_workspace_db_suffix_set" ]; then
    WORKSPACE_DB_SUFFIX="$_environment_workspace_db_suffix"
    export WORKSPACE_DB_SUFFIX
  else
    unset WORKSPACE_DB_SUFFIX
  fi
  unset WORKSPACE_REGISTERED_PORT
  if [ -n "$_environment_workspace_registered_port_set" ]; then
    WORKSPACE_REGISTERED_PORT="$_environment_workspace_registered_port"
  fi

  unset WORKSPACE_PORT
  [ -z "$_environment_provider_exports" ] || eval "$_environment_provider_exports"
  clear_manager_environment
  [ -z "$_environment_manager_environment" ] || eval "$_environment_manager_environment"

  if [ "$_environment_errexit_set" -eq 1 ]; then
    set -e
  fi
  return "$_environment_hook_status"
}

is_codex_git_workspace() {
  local _codex_home _codex_worktrees _git_worktree_path

  [ "$WORKSPACE_PROVIDER" = "git" ] || return 1
  _codex_home="${CODEX_HOME:-${HOME:-}/.codex}"
  _codex_worktrees=$(canonical_git_path "$_codex_home/worktrees")
  _git_worktree_path=$(git rev-parse --show-toplevel 2>/dev/null || true)
  _git_worktree_path=$(canonical_git_path "$_git_worktree_path")
  [ -n "$_codex_worktrees" ] && [ -n "$_git_worktree_path" ] || return 1
  case "$_git_worktree_path" in
    "$_codex_worktrees"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate and normalize a base port whose inclusive 10-port block must fit in
# the TCP range. Normalizing leading zeroes keeps shell arithmetic decimal.
validate_workspace_port_block() {
  _workspace_port="$1"
  case "$_workspace_port" in
    ""|*[!0-9]*)
      err "Port must be a number, got '$_workspace_port'"
      return 1
      ;;
  esac

  _workspace_port=$(printf '%s' "$_workspace_port" | sed 's/^0*//')
  [ -n "$_workspace_port" ] || _workspace_port=0
  if [ "${#_workspace_port}" -gt 5 ] || \
    [ "$_workspace_port" -lt 1 ] || [ "$_workspace_port" -gt 65526 ]; then
    err "Port block must fit within 1-65535, got base '$_workspace_port'"
    return 1
  fi

  printf '%s\n' "$_workspace_port"
}

# Print the base port for the current provider. An explicit Workspace override
# wins, followed by a registered Git reservation and manager-assigned ports;
# otherwise named worktrees receive deterministic 10-port blocks.
derive_workspace_port() {
  _default_port="$1"
  _provider_port=""
  case "$WORKSPACE_PROVIDER" in
    superconductor) _provider_port="${SUPERCONDUCTOR_PORT:-}" ;;
    conductor) _provider_port="${CONDUCTOR_PORT:-}" ;;
    git|"") _provider_port="${SUPERCONDUCTOR_PORT:-${CONDUCTOR_PORT:-}}" ;;
  esac
  _port_name="${WORKSPACE_NAME:-}"
  if [ -n "${WORKSPACE_PORT:-}" ]; then
    printf '%s\n' "$WORKSPACE_PORT"
    return
  fi

  if [ "$WORKSPACE_PROVIDER" = "git" ]; then
    if command -v registered_workspace_port >/dev/null 2>&1; then
      _registered_port=$(registered_workspace_port 2>/dev/null || true)
      if [ -n "$_registered_port" ]; then
        printf '%s\n' "$_registered_port"
        return
      fi
    fi
  fi

  if [ -n "$_provider_port" ]; then
    printf '%s\n' "$_provider_port"
  elif [ -n "$_port_name" ] && \
    { [ "$_port_name" != "default" ] || [ "$WORKSPACE_PROVIDER" = "git" ]; }; then
    _port_hash=$(printf '%s' "$_port_name" | cksum | awk '{print $1}')
    printf '%s\n' "$(( ((_port_hash % 900) * 10) + 50000 ))"
  else
    printf '%s\n' "$_default_port"
  fi
}

resolve_workspace_port() {
  _resolved_workspace_port=$(derive_workspace_port "$1") || return 1
  validate_workspace_port_block "$_resolved_workspace_port"
}

# ── App name detection ─────────────────────────────────────────────

# Detects the app name from the directory name, normalized for database use.
# Sets: APP_NAME
detect_app_name() {
  APP_NAME=$(basename "$(pwd)" | tr '-' '_')
}

# ── Application URL display ────────────────────────────────────

# Display configuration only: never evaluate template text as shell code.
# Complete URLs (including legacy run-hook overrides) retain precedence.
workspace_app_url() (
  if [ -n "${WORKSPACE_APP_URL:-}" ]; then
    printf '%s\n' "$WORKSPACE_APP_URL"
  elif [ -n "${WORKSPACE_APP_URL_TEMPLATE:-}" ]; then
    _url="$WORKSPACE_APP_URL_TEMPLATE"
    # Emit each literal prefix and port, then advance past that token. This
    # supports repeated tokens without interpreting shell or URL syntax.
    while :; do
      case "$_url" in
        *'{port}'*)
          printf '%s%s' "${_url%%"{port}"*}" "$1"
          _url=${_url#*"{port}"}
          ;;
        *) printf '%s\n' "$_url"; break ;;
      esac
    done
  elif [ "$USES_CADDY" = "true" ]; then
    printf 'https://%s.localhost:%s\n' "$(basename "$(pwd)")" "$1"
  else
    printf 'http://localhost:%s\n' "$1"
  fi
)
