#!/bin/sh
# workspace archive — Tear down a workspace.
#
# Flow:
#   1. Resolve workspace name
#   2. If default/no workspace: print message and exit
#   3. Run bin/workspace-archive-hook if it exists
#   4. Sweep ports (kill processes)
#   5. Drop workspace databases

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/db.sh"
. "$WORKSPACE_LIB/registry.sh"

_archive_registry_entry=""
if [ "${1:-}" = "--registry-entry" ]; then
  _archive_registry_entry="$2"
  load_registered_workspace "$_archive_registry_entry" || {
    err "Invalid workspace registry entry"
    exit 1
  }
  cd "$WORKSPACE_ROOT_PATH"
else
  resolve_workspace
  sanitize_workspace_name
  resolve_workspace_identity
fi

if [ -n "${WORKSPACE_INVALID_NAME:-}" ] || [ "$WORKSPACE_NAME" = "default" ]; then
  err "Workspace name cannot produce a safe isolated database suffix"
  exit 1
fi

# ── Default workspace: nothing to do ─────────────────────────────

if is_default_workspace; then
  step "No workspace detected, nothing to archive."
  exit 0
fi

# A manual Codex archive shares the registry lock with registration and prune.
# Registry-entry archives are already called by prune while it owns this lock.
if [ -z "$_archive_registry_entry" ] && [ "$WORKSPACE_PROVIDER" = "git" ]; then
  wait_for_workspace_registry_lock || {
    err "Workspace lifecycle is busy — try archive again"
    exit 1
  }
  trap 'release_workspace_registry_lock' EXIT HUP INT TERM
fi

header "Archiving workspace: $WORKSPACE_NAME"

# ── Port derivation (same logic as run) ──────────────────────────

if [ -n "${WORKSPACE_REGISTERED_PORT:-}" ]; then
  BASE_PORT="$WORKSPACE_REGISTERED_PORT"
else
  BASE_PORT=$(derive_workspace_port "")
fi

# ── Run archive hook (before DB drop — hook may need Rails) ──────

if [ -x bin/workspace-archive-hook ]; then
  header "Running archive hook"
  WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}" bin/workspace-archive-hook
fi

# ── Sweep ports ──────────────────────────────────────────────────

if [ -n "$BASE_PORT" ]; then
  case "$BASE_PORT" in
    *[!0-9]*) step "Port is not numeric ('$BASE_PORT') — skipping port sweep" ;;
    *)
      step "Sweeping ports $BASE_PORT-$((BASE_PORT + 9))"
      for offset in $(seq 0 9); do
        port=$((BASE_PORT + offset))
        pids=$(lsof -ti :"$port" 2>/dev/null || true)
        if [ -n "$pids" ]; then
          detail "Killing process on port $port"
          kill $pids 2>/dev/null || true
        fi
      done
      ok "Ports cleared"
      ;;
  esac
fi

# ── Drop workspace databases ────────────────────────────────────

if [ -n "$_archive_registry_entry" ] || [ "$WORKSPACE_PROVIDER" = "git" ]; then
  drop_workspace_databases_strict
  if [ -n "$_archive_registry_entry" ]; then
    unregister_workspace "$_archive_registry_entry"
  else
    unregister_workspace
  fi
else
  drop_workspace_databases
  unregister_workspace
fi

printf "\n${_green}  ✓${_reset} ${_bold}Archive complete${_reset}\n"
