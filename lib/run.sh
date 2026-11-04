#!/bin/sh
# workspace run — Start the dev server for a workspace.
#
# Flow:
#   1. Resolve workspace name and root path
#   2. Load linked .env defaults without overriding provider environment
#   3. Reserve a Git port block and export the DB suffix
#   4. Source bin/workspace-environment-hook if it exists
#   5. Detect app services, resolve authoritative ports, and export them
#   6. Check that foreman and Procfile.dev are present
#   7. Sweep ports (kill stale processes)
#   8. Source bin/workspace-run-hook if it exists
#   9. Display the configured application URL or the generic fallback
#  10. Start server via foreman

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/detect.sh"
. "$WORKSPACE_LIB/registry.sh"

# Help is a read-only command. Return before project detection or dotenv
# sourcing so a broken checkout cannot prevent the usage text from rendering.
# A bare "help" too: foreman would take it as a process name after the sweep.
case "${1:-}" in
  --help|-h|help)
    echo "Usage: workspace run"
    echo ""
    echo "Starts the dev server for a workspace."
    echo "Ports use WORKSPACE_PORT or provider-assigned ports, then fall back to"
    echo "the detected workspace name."
    echo "Other arguments go to foreman start, such as a process name:"
    echo "  workspace run web"
    exit 0
    ;;
esac

resolve_workspace
sanitize_workspace_name
resolve_workspace_identity

# Foreman's env-file values override its parent environment. Load the linked
# dotenv here instead, restoring values already exported by the manager. This
# also makes a dotenv WORKSPACE_PORT visible before Git port registration.
load_dotenv_defaults ./.env

if [ -n "$WORKSPACE_INVALID_NAME" ] || [ "$WORKSPACE_NAME" = "default" ]; then
  err "Workspace name cannot produce a safe isolated database suffix"
  exit 1
fi

# Recover resources from Git worktrees whose normal archive path was skipped or
# interrupted, without adding work for existing providers or empty repos.
if [ -n "${WORKSPACE_GIT_COMMON_DIR:-}" ] && \
  [ -d "$WORKSPACE_GIT_COMMON_DIR/workspace/registry" ]; then
  sh "$WORKSPACE_LIB/prune.sh" --quiet
fi

# A Codex run may be invoked before setup completes. Publish a collision-free
# port reservation before sweeping or starting any processes.
if [ "$WORKSPACE_PROVIDER" = "git" ]; then
  _requested_port=$(resolve_workspace_port "3000") || exit 1
  register_workspace "$_requested_port" || {
    err "Could not reserve workspace ports"
    exit 1
  }
fi

# ── DB env vars and project toolchain ────────────────────────────

if ! is_default_workspace; then
  export WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}"
else
  unset WORKSPACE_DB_SUFFIX
fi

# The environment hook prepares PATH/toolchain state. Workspace computes all
# authoritative service and port state afterward so the hook cannot make the
# reservation, sweep, and Foreman environment disagree.
source_workspace_environment_hook
detect_caddy
detect_vite
detect_foreman

# ── Port derivation ──────────────────────────────────────────────

# Priority and legacy defaults are centralized in common.sh.
BASE_PORT=$(resolve_workspace_port "3000") || exit 1

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

# ── Check prerequisites ──────────────────────────────────────────

# The sweep stops whatever is on these ports, so fail before it when the
# replacement cannot start.
if [ -z "$FOREMAN_CMD" ]; then
  err "foreman is not installed. Fix: gem install foreman"
  exit 1
fi
# Arguments reach foreman after our -f, so they may name another Procfile.
if [ ! -f Procfile.dev ] && [ "$#" -eq 0 ]; then
  err "Procfile.dev not found. workspace run starts the app with foreman from that file."
  exit 1
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

# ── Start server ─────────────────────────────────────────────────

header "Starting app"
# Keep the historical service-port choice after the hook: it may change PORT
# independently of HTTPS_PORT. Complete hook URLs still override the template.
if [ "$USES_CADDY" = "true" ]; then
  detail "$(workspace_app_url "$HTTPS_PORT")"
else
  detail "$(workspace_app_url "$PORT")"
fi
divider

exec $FOREMAN_CMD start -f Procfile.dev --env /dev/null "$@"
