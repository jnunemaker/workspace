#!/bin/sh
# workspace bootstrap — Initialize a workspace for development.
#
# Flow:
#   1. Resolve workspace name and root path
#   2. If default/main branch: run the app's ordinary setup script and exit
#   3. Sanitize workspace name (superset names only)
#   4. Symlink shared files from root
#   5. Export WORKSPACE_DB_SUFFIX
#   6. Materialize and patch database.yml when possible
#   7. Run bin/workspace-setup-hook, or fall back to the app setup script
#      when the dedicated hook is absent, then patch generated config
#   8. Prepare workspace-specific databases idempotently
#   9. Write .workspace file
#  10. Run bin/workspace-bootstrap-hook if it exists

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/detect.sh"
. "$WORKSPACE_LIB/db.sh"
. "$WORKSPACE_LIB/registry.sh"

[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && {
  echo "Usage: workspace bootstrap"
  echo ""
  echo "Root/default checkout: runs the project's ordinary setup script only."
  echo "Managed sibling ordering: shared files → WORKSPACE_DB_SUFFIX → database"
  echo "configuration hook → workspace setup hook (or legacy setup fallback) →"
  echo "database preparation → optional seed and bootstrap hooks."
  echo ""
  echo "Workspace never runs bin/update."
  exit 0
}

resolve_workspace
sanitize_workspace_name
resolve_workspace_identity
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

# A non-default provider identity that sanitizes to nothing must not fall
# through to the root/default path.
if [ -n "$WORKSPACE_INVALID_NAME" ]; then
  err "Workspace name cannot produce a safe isolated database suffix"
  exit 1
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

if [ "$WORKSPACE_NAME" = "default" ]; then
  err "Workspace name cannot produce a safe isolated database suffix"
  exit 1
fi

# ── Symlink shared files from root ───────────────────────────────

link_shared_file() {
  _shared_source="$1"
  _shared_destination="$2"

  # A tracked file belongs to the checked-out branch. Replacing it with the
  # root checkout's version would silently erase branch-specific tool/runtime
  # configuration (most commonly .tool-versions).
  if git ls-files --error-unmatch -- "$_shared_destination" >/dev/null 2>&1; then
    step "$_shared_destination is tracked — keeping workspace copy"
    return 0
  fi

  ln -sf "$_shared_source" "$_shared_destination"
  ok "$_shared_destination"
}

link_shared_directory() {
  _shared_source="$1"
  _shared_destination="$2"
  _shared_label="$3"

  if git ls-files -- "$_shared_destination" 2>/dev/null | grep -q .; then
    step "$_shared_destination contains tracked files — keeping workspace copy"
    return 0
  fi

  if [ -d "$_shared_destination" ] && [ ! -L "$_shared_destination" ]; then
    rm -rf "$_shared_destination"
  fi

  ln -sfn "$_shared_source" "$_shared_destination"
  ok "$_shared_label"
}

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
      link_shared_directory "$WORKSPACE_ROOT_PATH/.bundle" .bundle .bundle
    fi

    # Dotenv files
    for env_file in .env .env.development .env.test; do
      if [ -f "$WORKSPACE_ROOT_PATH/$env_file" ]; then
        link_shared_file "$WORKSPACE_ROOT_PATH/$env_file" "$env_file"
      fi
    done

    # Rails master key
    if [ -f "$WORKSPACE_ROOT_PATH/config/master.key" ]; then
      link_shared_file "$WORKSPACE_ROOT_PATH/config/master.key" config/master.key
    fi

    # Per-environment credential keys
    if [ -d "$WORKSPACE_ROOT_PATH/config/credentials" ]; then
      mkdir -p config/credentials
      for key_file in "$WORKSPACE_ROOT_PATH"/config/credentials/*.key; do
        if [ -f "$key_file" ]; then
          key_name=$(basename "$key_file")
          link_shared_file "$key_file" "config/credentials/$key_name"
        fi
      done
    fi

    # Active Storage files
    if [ -d "$WORKSPACE_ROOT_PATH/storage" ]; then
      link_shared_directory "$WORKSPACE_ROOT_PATH/storage" storage "storage/"
    fi

    # .tool-versions (asdf/mise)
    if [ -f "$WORKSPACE_ROOT_PATH/.tool-versions" ]; then
      link_shared_file "$WORKSPACE_ROOT_PATH/.tool-versions" .tool-versions
    fi

    # ngrok.yml
    if [ -f "$WORKSPACE_ROOT_PATH/ngrok.yml" ]; then
      link_shared_file "$WORKSPACE_ROOT_PATH/ngrok.yml" ngrok.yml
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

# ── Materialize and patch DB config before project setup ─────────

# Some projects generate config/database.yml locally. They can do that here so
# the CLI can isolate it before bin/setup performs any database work.
if [ -x bin/workspace-database-hook ]; then
  header "Preparing database configuration"
  bin/workspace-database-hook
fi

patch_database_yml

# ── Run managed setup hook or legacy setup fallback ─────────────

if [ -x bin/workspace-setup-hook ]; then
  header "Running workspace setup hook"
  bin/workspace-setup-hook
elif [ -n "$SETUP_SCRIPT" ]; then
  header "Running project setup (legacy fallback)"
  $SETUP_SCRIPT
fi

# A legacy setup script may itself create database.yml. Patch again afterward;
# patch_database_yml is idempotent when the earlier pass already handled it.

patch_database_yml

# ── Prepare workspace databases ──────────────────────────────────

create_workspace_databases

# ── Write .workspace file ────────────────────────────────────────

write_workspace_identity
ok "Wrote .workspace file"

register_workspace "$(derive_workspace_port "")"

# ── Run bootstrap hook ───────────────────────────────────────────

if [ -x bin/workspace-bootstrap-hook ]; then
  header "Running bootstrap hook"
  bin/workspace-bootstrap-hook
fi

printf "\n${_green}  ✓${_reset} ${_bold}Setup complete${_reset}\n"
