#!/bin/sh
# workspace run — Start the dev server for a workspace.
#
# Flow:
#   1. Resolve workspace name and root path
#   2. Derive ports (CONDUCTOR_PORT, or hash of workspace name, or default)
#   3. Export port env vars
#   4. Export DB env vars
#   5. Sweep ports (kill stale processes)
#   6. Run bin/workspace-run-hook if it exists
#   7. Start server via foreman

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/detect.sh"

resolve_workspace
sanitize_workspace_name
detect_caddy
detect_vite
detect_foreman

# ── Help ─────────────────────────────────────────────────────────

[ "$1" = "--help" -o "$1" = "-h" ] && {
  echo "Usage: workspace run"
  echo ""
  echo "Starts the dev server for a workspace."
  echo "Ports are derived from CONDUCTOR_PORT or the detected workspace name."
  exit 0
}

# Reconcile resources from externally removed Git worktrees before starting a
# new server, without adding work for existing providers or empty repos.
if [ -n "${WORKSPACE_GIT_COMMON_DIR:-}" ] && \
  [ -d "$WORKSPACE_GIT_COMMON_DIR/workspace/registry" ]; then
  sh "$WORKSPACE_LIB/prune.sh" --quiet
fi

# ── Port derivation ──────────────────────────────────────────────

# Priority and legacy defaults are centralized in common.sh.
BASE_PORT=$(derive_workspace_port "3000")

# Validate port is numeric
case "$BASE_PORT" in
  *[!0-9]*) err "Port must be a number, got '$BASE_PORT'"; exit 1 ;;
esac

# ── Export ports ─────────────────────────────────────────────────

if [ "$USES_CADDY" = "true" ]; then
  export HTTPS_PORT=$BASE_PORT
  export RAILS_PORT=$((BASE_PORT + 1))
  export CADDY_ADMIN_PORT=$((BASE_PORT + 2))
  export PORT=$HTTPS_PORT
else
  export PORT=$BASE_PORT
fi

if [ "$USES_VITE" = "true" ]; then
  if [ "$USES_CADDY" = "true" ]; then
    export VITE_RUBY_PORT=$((BASE_PORT + 3))
  else
    export VITE_RUBY_PORT=$((BASE_PORT + 1))
  fi
fi

# ── DB env vars ──────────────────────────────────────────────────

if ! is_default_workspace; then
  export WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}"
fi

# ── Sweep ports ──────────────────────────────────────────────────

for offset in $(seq 0 9); do
  port=$((BASE_PORT + offset))
  pids=$(lsof -ti :"$port" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
  fi
done

# ── Run hook ─────────────────────────────────────────────────────

if [ -x bin/workspace-run-hook ]; then
  . bin/workspace-run-hook
fi

# ── Check for foreman ────────────────────────────────────────────

if [ -z "$FOREMAN_CMD" ]; then
  err "foreman is not installed. Fix: gem install foreman"
  exit 1
fi

# ── Start server ─────────────────────────────────────────────────

header "Starting app"
if [ "$USES_CADDY" = "true" ]; then
  detail "https://$(basename "$(pwd)").localhost:${HTTPS_PORT}"
else
  detail "http://localhost:${PORT}"
fi
divider

exec $FOREMAN_CMD start -f Procfile.dev --env /dev/null "$@"
