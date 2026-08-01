#!/bin/sh
# workspace bootstrap — Initialize a workspace for development.
#
# Flow:
#   1. Resolve workspace name and root path
#   2. If default/main branch: just run app's own setup script and exit
#   3. Sanitize workspace name (superset names only)
#   4. Symlink shared files from root
#   5. Detect and run app's own setup script
#   6. Patch database.yml for workspace isolation (idempotent)
#   7. Create workspace-specific databases
#   8. Write .workspace file
#   9. Run bin/workspace-bootstrap-hook if it exists

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/detect.sh"
. "$WORKSPACE_LIB/db.sh"
. "$WORKSPACE_LIB/registry.sh"

resolve_workspace
sanitize_workspace_name
detect_app_name
detect_setup_script

# Reconcile resources from any Codex-managed worktrees removed since the last
# lifecycle event, without adding work for existing providers or empty repos.
if [ -n "${WORKSPACE_GIT_COMMON_DIR:-}" ] && \
  [ -d "$WORKSPACE_GIT_COMMON_DIR/workspace/registry" ]; then
  sh "$WORKSPACE_LIB/prune.sh" --quiet
fi

# Serialize the complete Codex setup with teardown for the same shared Git
# repository. Registration recognizes this process as the existing owner.
if [ "$WORKSPACE_PROVIDER" = "git" ]; then
  wait_for_workspace_registry_lock || {
    err "Workspace lifecycle is busy — run bootstrap again"
    exit 1
  }
  trap 'release_workspace_registry_lock' EXIT HUP INT TERM
fi

header "Setting up workspace"
if ! is_default_workspace; then
  detail "App: $APP_NAME"
  detail "Workspace: $WORKSPACE_NAME"
fi

# ── Default workspace: just run setup, no isolation ──────────────

if is_default_workspace; then
  if [ -n "$SETUP_SCRIPT" ]; then
    header "Running project setup"
    $SETUP_SCRIPT
  fi
  printf "\n${_green}  ✓${_reset} ${_bold}Setup complete${_reset}\n"
  exit 0
fi

# ── Symlink shared files from root ───────────────────────────────

if [ -n "$WORKSPACE_ROOT_PATH" ]; then
  # Detect if we're the root workspace itself (prevent circular symlinks)
  _root_real=$(cd "$WORKSPACE_ROOT_PATH" 2>/dev/null && pwd -P || echo "")
  _pwd_real=$(pwd -P)

  if [ "$_root_real" = "$_pwd_real" ]; then
    step "Root workspace detected — skipping symlinks"
  else
    header "Symlinking shared files"

    # .bundle — Bundler config and cached gems
    if [ -d "$WORKSPACE_ROOT_PATH/.bundle" ]; then
      if [ -d .bundle ] && [ ! -L .bundle ]; then
        rm -rf .bundle
      fi
      ln -sfn "$WORKSPACE_ROOT_PATH/.bundle" .bundle
      ok ".bundle"
    fi

    # Dotenv files
    for env_file in .env .env.development .env.test; do
      if [ -f "$WORKSPACE_ROOT_PATH/$env_file" ]; then
        ln -sf "$WORKSPACE_ROOT_PATH/$env_file" "$env_file"
        ok "$env_file"
      fi
    done

    # Rails master key
    if [ -f "$WORKSPACE_ROOT_PATH/config/master.key" ]; then
      ln -sf "$WORKSPACE_ROOT_PATH/config/master.key" config/master.key
      ok "config/master.key"
    fi

    # Per-environment credential keys
    if [ -d "$WORKSPACE_ROOT_PATH/config/credentials" ]; then
      mkdir -p config/credentials
      for key_file in "$WORKSPACE_ROOT_PATH"/config/credentials/*.key; do
        if [ -f "$key_file" ]; then
          key_name=$(basename "$key_file")
          ln -sf "$key_file" "config/credentials/$key_name"
          ok "config/credentials/$key_name"
        fi
      done
    fi

    # Active Storage files
    if [ -d "$WORKSPACE_ROOT_PATH/storage" ]; then
      if [ -d storage ] && [ ! -L storage ]; then
        rm -rf storage
      fi
      ln -sfn "$WORKSPACE_ROOT_PATH/storage" storage
      ok "storage/"
    fi

    # .tool-versions (asdf/mise)
    if [ -f "$WORKSPACE_ROOT_PATH/.tool-versions" ]; then
      ln -sf "$WORKSPACE_ROOT_PATH/.tool-versions" .tool-versions
      ok ".tool-versions"
    fi

    # ngrok.yml
    if [ -f "$WORKSPACE_ROOT_PATH/ngrok.yml" ]; then
      ln -sf "$WORKSPACE_ROOT_PATH/ngrok.yml" ngrok.yml
      ok "ngrok.yml"
    fi
  fi
else
  # No root path — standalone mode
  for env_file in .env .env.development .env.test; do
    if [ ! -f "$env_file" ]; then
      warn "$env_file not found — get a copy from the team"
    fi
  done
fi

# ── Source .env for setup scripts ────────────────────────────────

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

# ── Export workspace DB env vars ─────────────────────────────────

export WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}"

# ── Run app's own setup script ───────────────────────────────────

if [ -n "$SETUP_SCRIPT" ]; then
  header "Running project setup"
  $SETUP_SCRIPT
fi

# ── Patch database.yml for workspace isolation ───────────────────

patch_database_yml

# ── Create workspace databases ───────────────────────────────────

create_workspace_databases

# ── Write .workspace file ────────────────────────────────────────

printf '%s' "$WORKSPACE_NAME" > .workspace
ok "Wrote .workspace file"

register_workspace "$(derive_workspace_port "")"

# ── Run bootstrap hook ───────────────────────────────────────────

if [ -x bin/workspace-bootstrap-hook ]; then
  header "Running bootstrap hook"
  bin/workspace-bootstrap-hook
fi

printf "\n${_green}  ✓${_reset} ${_bold}Setup complete${_reset}\n"
