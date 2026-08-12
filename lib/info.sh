#!/bin/sh
# workspace info — Show the current workspace identity and resources.

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/detect.sh"
. "$WORKSPACE_LIB/registry.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Usage: workspace info"
  echo ""
  echo "Shows the detected provider, workspace name, root, database suffix,"
  echo "application URL, and the 10-port block reserved for this workspace."
  exit 0
fi

resolve_workspace
sanitize_workspace_name
resolve_workspace_identity
detect_caddy
detect_vite
load_dotenv_defaults ./.env

if [ -n "$WORKSPACE_INVALID_NAME" ] || [ "$WORKSPACE_NAME" = "default" ]; then
  err "Workspace name cannot produce a safe isolated database suffix"
  exit 1
fi

BASE_PORT=$(resolve_workspace_port "3000") || exit 1

case "$WORKSPACE_PROVIDER" in
  git) _provider="git" ;;
  "") _provider="default" ;;
  *) _provider="$WORKSPACE_PROVIDER" ;;
esac

_workspace_name="${WORKSPACE_NAME:-default}"
_workspace_root="$WORKSPACE_ROOT_PATH"
if [ -z "$_workspace_root" ]; then
  _workspace_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
fi

if is_default_workspace; then
  _workspace_suffix="(none)"
else
  _workspace_suffix="_${WORKSPACE_NAME}"
fi

if [ -n "${WORKSPACE_APP_URL:-}" ]; then
  _workspace_url="$WORKSPACE_APP_URL"
elif [ "$USES_CADDY" = "true" ]; then
  _workspace_url="https://$(basename "$(pwd)").localhost:${BASE_PORT}"
else
  _workspace_url="http://localhost:${BASE_PORT}"
fi

echo "Provider: $_provider"
echo "Workspace: $_workspace_name"
echo "Identity source: $WORKSPACE_IDENTITY_SOURCE"
echo "Root: $_workspace_root"
echo "Database suffix: $_workspace_suffix"
echo "URL: $_workspace_url"
echo "Ports: ${BASE_PORT}-$((BASE_PORT + 9))"
echo "  App: $BASE_PORT"
if [ "$USES_CADDY" = "true" ]; then
  echo "  Rails: $((BASE_PORT + 1))"
  echo "  Caddy admin: $((BASE_PORT + 2))"
fi
if [ "$USES_VITE" = "true" ]; then
  if [ "$USES_CADDY" = "true" ]; then
    echo "  Vite: $((BASE_PORT + 3))"
  else
    echo "  Vite: $((BASE_PORT + 1))"
  fi
fi
