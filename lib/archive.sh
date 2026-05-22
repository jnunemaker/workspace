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

resolve_workspace
sanitize_workspace_name
prefer_workspace_file

# ── Default workspace: nothing to do ─────────────────────────────

if is_default_workspace; then
  step "No workspace detected, nothing to archive."
  exit 0
fi

header "Archiving workspace: $WORKSPACE_NAME"

# ── Port derivation (same logic as run) ──────────────────────────

_ws_name="${SUPERCONDUCTOR_WORKSPACE_NAME:-$SUPERSET_WORKSPACE_NAME}"
if [ -n "$CONDUCTOR_PORT" ]; then
  BASE_PORT=$CONDUCTOR_PORT
elif [ -n "$_ws_name" ] && [ "$_ws_name" != "default" ]; then
  _hash=$(printf '%s' "$_ws_name" | cksum | awk '{print $1}')
  BASE_PORT=$(( ((_hash % 900) * 10) + 50000 ))
else
  BASE_PORT=""
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

drop_workspace_databases

printf "\n${_green}  ✓${_reset} ${_bold}Archive complete${_reset}\n"
