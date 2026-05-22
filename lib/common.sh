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
  WORKSPACE_ROOT_PATH="${SUPERCONDUCTOR_ROOT_PATH:-${SUPERSET_ROOT_PATH:-$CONDUCTOR_ROOT_PATH}}"
  WORKSPACE_NAME="${SUPERCONDUCTOR_WORKSPACE_NAME:-${SUPERSET_WORKSPACE_NAME:-$CONDUCTOR_WORKSPACE_NAME}}"

  # "default" is superset's name for the main branch — treat as no workspace
  if [ "$WORKSPACE_NAME" = "default" ]; then
    WORKSPACE_NAME=""
  fi
}

# Returns true if this is the "default" / main branch workspace (no isolation needed)
is_default_workspace() {
  [ -z "$WORKSPACE_NAME" ]
}

# ── Prefer .workspace file over env var ───────────────────────────

# .workspace is written by bootstrap with the name the dev/test databases
# were created under. The workspace orchestrator (Conductor/Superset) can
# pass a different name on later invocations — observed when the workspace
# directory is renamed, or when the name is re-derived from the current
# git branch tail. Trust the file so the DB suffix stays consistent with
# what bootstrap actually created. Delete .workspace and rerun bootstrap
# to genuinely re-key the workspace.
#
# Sets: WORKSPACE_NAME (overwritten with file content when file exists)
prefer_workspace_file() {
  [ -f .workspace ] || return 0
  _file_workspace=$(cat .workspace)
  [ -z "$_file_workspace" ] && return 0
  if [ -n "$WORKSPACE_NAME" ] && [ "$_file_workspace" != "$WORKSPACE_NAME" ]; then
    warn "Workspace name drift: env=\"$WORKSPACE_NAME\", .workspace=\"$_file_workspace\" — using the file."
  fi
  WORKSPACE_NAME="$_file_workspace"
}

# ── Workspace name sanitization ────────────────────────────────────

# Sanitizes a workspace name for safe use in database names and file paths.
# Only applied to Superset workspace names (conductor names are assumed clean).
# Sets: WORKSPACE_NAME (overwritten with sanitized value)
sanitize_workspace_name() {
  _raw_name="${SUPERCONDUCTOR_WORKSPACE_NAME:-$SUPERSET_WORKSPACE_NAME}"
  if [ -n "$_raw_name" ] && [ "$_raw_name" != "default" ]; then
    WORKSPACE_NAME=$(printf '%s' "$_raw_name" \
      | tr -cs 'a-zA-Z0-9_-' '-' \
      | sed 's/--*/-/g; s/^-//; s/-$//' \
      | cut -c1-40 \
      | sed 's/-$//')
  fi
}

# ── App name detection ─────────────────────────────────────────────

# Detects the app name from the directory name, normalized for database use.
# Sets: APP_NAME
detect_app_name() {
  APP_NAME=$(basename "$(pwd)" | tr '-' '_')
}
