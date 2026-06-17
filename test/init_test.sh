#!/bin/sh
# Tests for lib/init.sh — workspace init command.

cd "$(dirname "$0")"
. ./test_helper.sh

run_init() {
  sh "$WORKSPACE_HOME/lib/init.sh" >/dev/null 2>&1
}

# ── init: creates .conductor/settings.toml ──────────────────────

app_dir=$(create_fake_app "init-conductor")
cd "$app_dir"
run_init

assert_true ".conductor/settings.toml created" [ -f .conductor/settings.toml ]
assert_true "settings.toml has schema" grep -q 'settings.repo.schema.json' .conductor/settings.toml
assert_true "settings.toml has scripts table" grep -q '\[scripts\]' .conductor/settings.toml
assert_true "settings.toml has setup script" grep -q 'setup = "workspace bootstrap"' .conductor/settings.toml
assert_true "settings.toml has run script" grep -q 'run = "workspace run"' .conductor/settings.toml
assert_true "settings.toml has archive script" grep -q 'archive = "workspace archive"' .conductor/settings.toml

# ── init: creates .superconductor/config.json ───────────────────

assert_true ".superconductor/config.json created" [ -f .superconductor/config.json ]
assert_true "superconductor config has setup script" grep -q 'workspace bootstrap' .superconductor/config.json
assert_true "superconductor config has run script" grep -q 'workspace run' .superconductor/config.json

# ── init: creates .superset/config.json ─────────────────────────

assert_true ".superset/config.json created" [ -f .superset/config.json ]
assert_true "superset config has setup script" grep -q 'workspace bootstrap' .superset/config.json
assert_true "superset config has teardown script" grep -q 'workspace archive' .superset/config.json

# ── init: creates bin/workspace-seed ────────────────────────────

assert_true "bin/workspace-seed created" [ -f bin/workspace-seed ]
assert_true "bin/workspace-seed is executable" [ -x bin/workspace-seed ]
assert_true "seed file mentions fixtures" grep -q 'db:fixtures:load' bin/workspace-seed
assert_true "seed file mentions db:seed" grep -q 'db:seed' bin/workspace-seed
assert_true "seed file mentions custom rake" grep -q 'plan:seed' bin/workspace-seed

# ── init: doesn't overwrite existing bin/workspace-seed ─────────

app_dir=$(create_fake_app "init-seed-exists")
cd "$app_dir"
cat > bin/workspace-seed <<'EOF'
#!/bin/sh
bin/rails db:fixtures:load
EOF
chmod +x bin/workspace-seed

run_init
assert_true "bin/workspace-seed not overwritten" grep -q 'db:fixtures:load' bin/workspace-seed
assert_false "no scaffold comments added" grep -q 'plan:seed' bin/workspace-seed

# ── init: migrates a legacy conductor.json ──────────────────────

app_dir=$(create_fake_app "init-migrate-conductor")
cd "$app_dir"
cat > conductor.json <<'EOF'
{
  "scripts": {
    "setup": "bin/legacy-setup",
    "run": "bin/legacy-run",
    "archive": "bin/legacy-archive"
  }
}
EOF

run_init

assert_false "legacy conductor.json removed" [ -f conductor.json ]
assert_true "settings.toml created from migration" [ -f .conductor/settings.toml ]
assert_true "migration keeps schema" grep -q 'settings.repo.schema.json' .conductor/settings.toml
assert_true "migration has scripts table" grep -q '\[scripts\]' .conductor/settings.toml
assert_true "migrated setup script" grep -q 'setup = "bin/legacy-setup"' .conductor/settings.toml
assert_true "migrated run script" grep -q 'run = "bin/legacy-run"' .conductor/settings.toml
assert_true "migrated archive script" grep -q 'archive = "bin/legacy-archive"' .conductor/settings.toml

# ── init: migrating a scriptless conductor.json falls back to defaults ──

app_dir=$(create_fake_app "init-migrate-empty")
cd "$app_dir"
cat > conductor.json <<'EOF'
{}
EOF

run_init

assert_false "scriptless conductor.json removed" [ -f conductor.json ]
assert_true "fallback settings.toml created" [ -f .conductor/settings.toml ]
assert_true "fallback uses default setup script" grep -q 'setup = "workspace bootstrap"' .conductor/settings.toml
assert_true "fallback uses default run script" grep -q 'run = "workspace run"' .conductor/settings.toml
assert_true "fallback uses default archive script" grep -q 'archive = "workspace archive"' .conductor/settings.toml

# ── init: idempotent — doesn't overwrite existing configs ───────

app_dir=$(create_fake_app "init-idempotent")
cd "$app_dir"

mkdir -p .conductor
cat > .conductor/settings.toml <<'EOF'
[scripts]
setup = "bin/custom-setup"
EOF

mkdir -p .superconductor
cat > .superconductor/config.json <<'EOF'
{
  "setup": ["bin/custom-setup"]
}
EOF
mkdir -p .superset
cat > .superset/config.json <<'EOF'
{
  "setup": ["bin/custom-setup"]
}
EOF

run_init

assert_true "settings.toml not overwritten" grep -q 'custom-setup' .conductor/settings.toml
assert_true "superconductor config not overwritten" grep -q 'custom-setup' .superconductor/config.json
assert_true "superset config not overwritten" grep -q 'custom-setup' .superset/config.json

# ── init: adds .workspace to .gitignore ─────────────────────────

# Creates .gitignore when missing
app_dir=$(create_fake_app "init-gitignore-missing")
cd "$app_dir"
run_init
assert_true ".gitignore created" [ -f .gitignore ]
assert_true ".gitignore contains .workspace" grep -qxF '.workspace' .gitignore

# Appends to existing .gitignore
app_dir=$(create_fake_app "init-gitignore-existing")
cd "$app_dir"
printf 'node_modules\ntmp/\n' > .gitignore
run_init
assert_true "existing entry preserved" grep -qxF 'node_modules' .gitignore
assert_true ".workspace appended" grep -qxF '.workspace' .gitignore

# Idempotent — doesn't duplicate .workspace
app_dir=$(create_fake_app "init-gitignore-idempotent")
cd "$app_dir"
printf '.workspace\n' > .gitignore
run_init
count=$(grep -cxF '.workspace' .gitignore)
assert_equal ".workspace appears once" "1" "$count"

# Handles .gitignore without trailing newline
app_dir=$(create_fake_app "init-gitignore-no-newline")
cd "$app_dir"
printf 'tmp/' > .gitignore
run_init
assert_true "previous entry intact" grep -qxF 'tmp/' .gitignore
assert_true ".workspace on its own line" grep -qxF '.workspace' .gitignore

# ── init: patches database.yml with WORKSPACE_DB_SUFFIX ─────────

if command -v ruby >/dev/null 2>&1; then
  app_dir=$(create_fake_app "init-db-patch")
  cd "$app_dir"
  cat > config/database.yml <<'YAML'
development:
  database: myapp_development

test:
  database: myapp_test
YAML

  run_init

  assert_true "database.yml patched with WORKSPACE_DB_SUFFIX" grep -q 'WORKSPACE_DB_SUFFIX' config/database.yml
  assert_false "database.yml does not use DEV_ENV_NUMBER" grep -q 'DEV_ENV_NUMBER' config/database.yml
  assert_false "database.yml does not use TEST_ENV_NUMBER" grep -q 'TEST_ENV_NUMBER' config/database.yml
fi

# ── init: skips database.yml patch when missing ─────────────────

app_dir=$(create_fake_app "init-no-db")
cd "$app_dir"
rm -f config/database.yml

run_init
assert_equal "no database.yml → no error" "0" "$?"
assert_false "no database.yml created" [ -f config/database.yml ]

report "init.sh"
