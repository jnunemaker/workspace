#!/bin/sh
# workspace init — Set up a project to work with workspace CLI.
#
# Flow:
#   1. Patch database.yml for workspace isolation (idempotent)
#   2. Create conductor.json
#   3. Create .superset/config.json
#   4. Create .conductor/ directory
#   5. Create bin/workspace-seed (commented scaffold)

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

# ── Create bin/workspace-seed ────────────────────────────────────

if [ -f bin/workspace-seed ]; then
  step "bin/workspace-seed already exists"
else
  cat > bin/workspace-seed <<'EOF'
#!/bin/sh
# Seed the workspace database after schema load.
# Uncomment the line that matches your project's seed strategy.
#
# Fixtures (test data loaded into dev):
#   bin/rails db:fixtures:load
#
# Seeds file (db/seeds.rb):
#   bin/rails db:seed
#
# Custom rake task:
#   bin/rails plan:seed
#
# Nothing needed? Delete this file.

EOF
  chmod +x bin/workspace-seed
  ok "Created bin/workspace-seed (edit to configure seeding)"
fi

printf "\n${_green}  ✓${_reset} ${_bold}Project is now workspace-ready${_reset}\n"
