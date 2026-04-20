#!/bin/sh
# workspace init — Set up a project to work with workspace CLI.
#
# Flow:
#   1. Patch database.yml for workspace isolation (idempotent)
#   2. Create conductor.json
#   3. Create .superset/config.json
#   4. Create .conductor/ directory

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/db.sh"

header "Initializing workspace support"

# ── Patch database.yml ──────────────────────────────────────────

patch_database_yml

# ── Create conductor.json ───────────────────────────────────────

if [ -f conductor.json ]; then
  step "conductor.json already exists"
else
  cat > conductor.json <<'EOF'
{
  "scripts": {
    "setup": "workspace bootstrap",
    "run": "workspace run",
    "archive": "workspace archive"
  }
}
EOF
  ok "Created conductor.json"
fi

# ── Create .conductor/ directory ────────────────────────────────

if [ -d .conductor ]; then
  step ".conductor/ already exists"
else
  mkdir -p .conductor
  ok "Created .conductor/"
fi

# ── Create .superset/config.json ────────────────────────────────

if [ -f .superset/config.json ]; then
  step ".superset/config.json already exists"
else
  mkdir -p .superset
  cat > .superset/config.json <<'EOF'
{
  "setup": ["workspace bootstrap"],
  "teardown": ["workspace archive"]
}
EOF
  ok "Created .superset/config.json"
fi

printf "\n${_green}  ✓${_reset} ${_bold}Project is now workspace-ready${_reset}\n"
