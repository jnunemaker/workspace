#!/bin/sh
# workspace init — Set up a project to work with workspace CLI.
#
# Flow:
#   1. Patch database.yml for workspace isolation (idempotent)
#   2. Create .conductor/settings.toml
#   3. Create .superconductor/config.json
#   4. Create .superset/config.json
#   5. Create bin/workspace-seed (commented scaffold)
#   6. Add .workspace to .gitignore

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/db.sh"

header "Initializing workspace support"

# ── Patch database.yml ──────────────────────────────────────────

patch_database_yml

# ── Create .conductor/settings.toml ─────────────────────────────

if [ -f .conductor/settings.toml ]; then
  step ".conductor/settings.toml already exists"
else
  mkdir -p .conductor
  cat > .conductor/settings.toml <<'EOF'
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

[scripts]
setup = "workspace bootstrap"
run = "workspace run"
archive = "workspace archive"
EOF
  ok "Created .conductor/settings.toml"
fi

# ── Create .superconductor/config.json ──────────────────────────

if [ -f .superconductor/config.json ]; then
  step ".superconductor/config.json already exists"
else
  mkdir -p .superconductor
  cat > .superconductor/config.json <<'EOF'
{
  "setup": ["workspace bootstrap"],
  "run": ["workspace run"]
}
EOF
  ok "Created .superconductor/config.json"
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

# ── Add .workspace to .gitignore ────────────────────────────────

if [ -f .gitignore ] && grep -qxF '.workspace' .gitignore; then
  step ".workspace already in .gitignore"
elif [ -f .gitignore ]; then
  [ -z "$(tail -c1 .gitignore 2>/dev/null)" ] || printf '\n' >> .gitignore
  printf '.workspace\n' >> .gitignore
  ok "Added .workspace to .gitignore"
else
  printf '.workspace\n' > .gitignore
  ok "Created .gitignore with .workspace"
fi

printf "\n${_green}  ✓${_reset} ${_bold}Project is now workspace-ready${_reset}\n"
