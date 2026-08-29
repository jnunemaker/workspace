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

# Help must return before archive inspects or removes workspace resources.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: workspace archive

Stops processes using this workspace's reserved ports and drops its development
and test databases. Runs bin/workspace-archive-hook first when present.
The original checkout is left alone.
EOF
  exit 0
fi

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

# Match run and info when a non-Git provider stores WORKSPACE_PORT in the
# linked dotenv file. Registry-entry cleanup still uses its recorded port.
set +e
load_dotenv_defaults ./.env
_dotenv_status=$?
set -e
if [ "$_dotenv_status" -ne 0 ]; then
  err "Could not load .env — archive stopped before cleanup"
  exit 1
fi

# ── Port derivation (same logic as run) ──────────────────────────

if [ -n "${WORKSPACE_REGISTERED_PORT:-}" ]; then
  if ! BASE_PORT=$(validate_workspace_port_block "$WORKSPACE_REGISTERED_PORT"); then
    warn "Skipping invalid registered port block"
    BASE_PORT=""
  fi
else
  if ! BASE_PORT=$(resolve_workspace_port ""); then
    warn "Skipping invalid workspace port block"
    BASE_PORT=""
  fi
fi

# ── Run archive hook (before DB drop — hook may need Rails) ──────

if [ -x bin/workspace-archive-hook ]; then
  header "Running archive hook"
  WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}" bin/workspace-archive-hook
fi

# ── Sweep ports ──────────────────────────────────────────────────

if [ -n "$BASE_PORT" ]; then
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
