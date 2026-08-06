#!/bin/sh
# Tests for lib/db.sh — database.yml patching logic.
# Does NOT test actual DB creation/drop (requires Rails).

cd "$(dirname "$0")"
. ./test_helper.sh
. "$WORKSPACE_HOME/lib/db.sh"

# ── patch_database_yml: already patched ──────────────────────────

app_dir=$(create_fake_app "already-patched")
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  primary:
    database: myapp_development<%= ENV["WORKSPACE_DB_SUFFIX"] %>
test:
  primary:
    database: myapp_test<%= ENV["WORKSPACE_DB_SUFFIX"] %>
YAML

patch_database_yml 2>/dev/null
content=$(cat config/database.yml)
# Should be unchanged
assert_true "already patched is no-op" echo "$content" | grep -q 'WORKSPACE_DB_SUFFIX'

# ── patch_database_yml: injects before legacy env vars ──────────

app_dir=$(create_fake_app "has-legacy-vars")
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  primary:
    database: myapp_development<%= ENV["DEV_ENV_NUMBER"] %>
test:
  primary:
    database: myapp_test<%= ENV["TEST_ENV_NUMBER"] %>
YAML

patch_database_yml 2>/dev/null
assert_true "WORKSPACE_DB_SUFFIX injected" grep -q 'WORKSPACE_DB_SUFFIX' config/database.yml
assert_true "DEV_ENV_NUMBER preserved" grep -q 'DEV_ENV_NUMBER' config/database.yml
assert_true "TEST_ENV_NUMBER preserved" grep -q 'TEST_ENV_NUMBER' config/database.yml
assert_true "dev: suffix before env number" grep -q 'WORKSPACE_DB_SUFFIX.*DEV_ENV_NUMBER' config/database.yml
assert_true "test: suffix before env number" grep -q 'WORKSPACE_DB_SUFFIX.*TEST_ENV_NUMBER' config/database.yml

# ── patch_database_yml: already has DB_SUFFIX ────────────────────

app_dir=$(create_fake_app "has-db-suffix")
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  database: myapp_dev<%= ENV["DB_SUFFIX"] %>
YAML

patch_database_yml 2>/dev/null
content=$(cat config/database.yml)
assert_true "DB_SUFFIX treated as already patched" echo "$content" | grep -q 'DB_SUFFIX'

# ── patch_database_yml: no database.yml ──────────────────────────

app_dir=$(create_fake_app "no-db-yml")
cd "$app_dir"
rm -f config/database.yml
# Should not error
patch_database_yml 2>/dev/null
assert_equal "no database.yml → no error" "0" "$?"

# ── patch_database_yml: needs patching ───────────────────────────

# Only test if ruby is available
if command -v ruby >/dev/null 2>&1; then
  app_dir=$(create_fake_app "needs-patch")
  cd "$app_dir"
  cat > config/database.yml <<'YAML'
default: &default
  adapter: postgresql

development:
  primary:
    <<: *default
    database: myapp_development
  queue:
    <<: *default
    database: myapp_development

test:
  primary:
    <<: *default
    database: myapp_test
  queue:
    <<: *default
    database: myapp_test

production:
  primary:
    <<: *default
    url: <%= ENV["DATABASE_URL"] %>
YAML

  patch_database_yml 2>/dev/null
  content=$(cat config/database.yml)

  # All dev+test databases should use WORKSPACE_DB_SUFFIX
  suffix_count=$(echo "$content" | grep -c 'WORKSPACE_DB_SUFFIX' || true)
  assert_equal "all dev+test databases patched (4 entries)" "4" "$suffix_count"

  # Production should NOT be touched
  prod_lines=$(echo "$content" | grep 'production' | grep 'WORKSPACE_DB_SUFFIX' || true)
  assert_equal "production not patched" "" "$prod_lines"

  # Specific line checks
  dev_match=$(echo "$content" | grep 'myapp_development<%= ENV\["WORKSPACE_DB_SUFFIX"\] %>' || true)
  assert_true "dev primary patched" [ -n "$dev_match" ]
  test_match=$(echo "$content" | grep 'myapp_test<%= ENV\["WORKSPACE_DB_SUFFIX"\] %>' || true)
  assert_true "test primary patched" [ -n "$test_match" ]
fi

# ── create_workspace_databases: runs bin/workspace-seed ──────────

app_dir=$(create_fake_app "seed-runs")
cd "$app_dir"

# Fake bin/rails so db:prepare succeeds
cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x bin/rails

# Create a seed script that writes a marker file
cat > bin/workspace-seed <<'SCRIPT'
#!/bin/sh
touch .seed-ran
SCRIPT
chmod +x bin/workspace-seed

WORKSPACE_NAME="test-ws"
create_workspace_databases 2>/dev/null

assert_true "bin/workspace-seed was executed" [ -f .seed-ran ]

# ── create_workspace_databases: seeds projects without Rails ────

app_dir=$(create_fake_app "seed-without-rails")
cd "$app_dir"

cat > bin/workspace-seed <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$WORKSPACE_DB_SUFFIX" > .seed-suffix
SCRIPT
chmod +x bin/workspace-seed

WORKSPACE_NAME="non-rails-ws"
assert_true "non-Rails database setup still succeeds" create_workspace_databases
assert_true "bin/workspace-seed runs without bin/rails" [ -f .seed-suffix ]
assert_equal "non-Rails seed receives workspace suffix" "_non-rails-ws" "$(cat .seed-suffix)"

# ── create_workspace_databases: skips seed when not present ─────

app_dir=$(create_fake_app "seed-missing")
cd "$app_dir"

cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x bin/rails

WORKSPACE_NAME="test-ws"
create_workspace_databases 2>/dev/null

assert_false "no seed without bin/workspace-seed" [ -f .seed-ran ]

# ── create_workspace_databases: skips seed when not executable ──

app_dir=$(create_fake_app "seed-not-executable")
cd "$app_dir"

cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x bin/rails

cat > bin/workspace-seed <<'SCRIPT'
#!/bin/sh
touch .seed-ran
SCRIPT
# deliberately NOT chmod +x

WORKSPACE_NAME="test-ws"
create_workspace_databases 2>/dev/null

assert_false "non-executable seed is skipped" [ -f .seed-ran ]

# ── create_workspace_databases: idempotent and failure-aware ────

app_dir=$(create_fake_app "prepare-command")
cd "$app_dir"
printf 'development:\n  database: app_development\n' > config/database.yml
prepare_log="$TEST_TMP/prepare-command.log"
cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf '%s:%s:%s\n' "$RAILS_ENV" "$WORKSPACE_DB_SUFFIX" "$*" >> "$WORKSPACE_TEST_PREPARE_LOG"
exit 0
SCRIPT
chmod +x bin/rails
WORKSPACE_NAME="prepared-ws"
WORKSPACE_TEST_PREPARE_LOG="$prepare_log"
export WORKSPACE_TEST_PREPARE_LOG
assert_true "database preparation succeeds" create_workspace_databases
assert_true "development uses db:prepare" grep -q '^development:_prepared-ws:db:prepare$' "$prepare_log"
assert_true "test uses db:prepare" grep -q '^test:_prepared-ws:db:prepare$' "$prepare_log"
assert_false "database preparation does not schema-load" grep -q 'db:schema:load' "$prepare_log"

# Older Rails versions without db:prepare use create + migrate, never a
# destructive schema load. Other preparation failures must not fall back.
app_dir=$(create_fake_app "legacy-rails-prepare")
cd "$app_dir"
legacy_prepare_log="$TEST_TMP/legacy-rails-prepare.log"
cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf '%s:%s\n' "$RAILS_ENV" "$*" >> "$WORKSPACE_TEST_LEGACY_PREPARE_LOG"
case "$1" in
  db:prepare) exit 1 ;;
  --tasks) printf 'rails db:create\nrails db:migrate\n'; exit 0 ;;
  db:create|db:migrate) exit 0 ;;
  *) exit 1 ;;
esac
SCRIPT
chmod +x bin/rails
WORKSPACE_NAME="legacy-rails-ws"
WORKSPACE_TEST_LEGACY_PREPARE_LOG="$legacy_prepare_log"
export WORKSPACE_TEST_LEGACY_PREPARE_LOG
assert_true "Rails without db:prepare uses safe fallback" create_workspace_databases
assert_true "legacy development database is created" grep -q '^development:db:create$' "$legacy_prepare_log"
assert_true "legacy development database is migrated" grep -q '^development:db:migrate$' "$legacy_prepare_log"
assert_true "legacy test database is created" grep -q '^test:db:create$' "$legacy_prepare_log"
assert_true "legacy test database is migrated" grep -q '^test:db:migrate$' "$legacy_prepare_log"
assert_false "legacy fallback never schema-loads" grep -q 'db:schema:load' "$legacy_prepare_log"

prepare_failure_log="$TEST_TMP/prepare-runtime-failure.log"
cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf '%s:%s\n' "$RAILS_ENV" "$*" >> "$WORKSPACE_TEST_PREPARE_FAILURE_LOG"
case "$1" in
  db:prepare) exit 1 ;;
  --tasks) printf 'rails db:prepare\n'; exit 0 ;;
  db:create|db:migrate) touch .unsafe-prepare-fallback; exit 0 ;;
  *) exit 1 ;;
esac
SCRIPT
chmod +x bin/rails
cat > bin/workspace-seed <<'SCRIPT'
#!/bin/sh
touch .seed-ran-after-prepare-failure
SCRIPT
chmod +x bin/workspace-seed
WORKSPACE_TEST_PREPARE_FAILURE_LOG="$prepare_failure_log"
export WORKSPACE_TEST_PREPARE_FAILURE_LOG
prepare_failure_output="$TEST_TMP/prepare-failure-output.log"
assert_false "present db:prepare task propagates runtime failures" create_workspace_databases > "$prepare_failure_output" 2>&1
assert_false "failed db:prepare never uses legacy fallback" [ -f .unsafe-prepare-fallback ]
assert_false "failed database preparation does not seed" [ -f .seed-ran-after-prepare-failure ]
assert_false "failed database preparation is not reported ready" grep -q 'database ready' "$prepare_failure_output"

cat > bin/rails <<'SCRIPT'
#!/bin/sh
touch .rails-called
SCRIPT
chmod +x bin/rails
WORKSPACE_NAME="default"
assert_false "literal default cannot be an isolated database suffix" create_workspace_databases
assert_false "default protection runs before Rails" [ -f .rails-called ]
assert_false "literal default cannot use legacy database cleanup" drop_workspace_databases
assert_false "literal default cannot use strict database cleanup" drop_workspace_databases_strict
assert_false "cleanup default protection runs before Rails" [ -f .rails-called ]

# ── drop_workspace_databases_strict ─────────────────────────────

non_rails_dir="$TEST_TMP/non-rails"
mkdir -p "$non_rails_dir"
cd "$non_rails_dir"
WORKSPACE_NAME="non-rails-ws"
assert_true "strict cleanup is a no-op for non-Rails projects" drop_workspace_databases_strict

app_dir=$(create_fake_app "strict-drop-failure")
cd "$app_dir"
printf 'development:\n  database: app_development\n' > config/database.yml
cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 1
SCRIPT
chmod +x bin/rails
WORKSPACE_NAME="strict-failure-ws"
assert_false "strict cleanup reports Rails drop failures" drop_workspace_databases_strict

report "db.sh"
