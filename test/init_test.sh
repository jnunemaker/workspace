#!/bin/sh
# Tests for lib/init.sh — workspace init command.

cd "$(dirname "$0")"
. ./test_helper.sh

run_init() {
  sh "$WORKSPACE_HOME/lib/init.sh" >/dev/null 2>&1
}

# ── init: creates conductor.json ────────────────────────────────

app_dir=$(create_fake_app "init-conductor")
cd "$app_dir"
run_init

assert_true "conductor.json created" [ -f conductor.json ]
assert_true "conductor.json has setup script" grep -q '"setup": "workspace bootstrap"' conductor.json
assert_true "conductor.json has run script" grep -q '"run": "workspace run"' conductor.json
assert_true "conductor.json has archive script" grep -q '"archive": "workspace archive"' conductor.json

# ── init: creates .conductor/ directory ─────────────────────────

assert_true ".conductor/ directory created" [ -d .conductor ]

# ── init: creates .superset/config.json ─────────────────────────

assert_true ".superset/config.json created" [ -f .superset/config.json ]
assert_true "superset config has setup script" grep -q 'workspace bootstrap' .superset/config.json
assert_true "superset config has teardown script" grep -q 'workspace archive' .superset/config.json

# ── init: idempotent — doesn't overwrite existing configs ───────

app_dir=$(create_fake_app "init-idempotent")
cd "$app_dir"

cat > conductor.json <<'EOF'
{
  "scripts": {
    "setup": "bin/custom-setup"
  }
}
EOF

mkdir -p .conductor
mkdir -p .superset
cat > .superset/config.json <<'EOF'
{
  "setup": ["bin/custom-setup"]
}
EOF

run_init

assert_true "conductor.json not overwritten" grep -q 'custom-setup' conductor.json
assert_true "superset config not overwritten" grep -q 'custom-setup' .superset/config.json

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
