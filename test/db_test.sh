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
    database: myapp_development<%= ENV["DEV_ENV_NUMBER"] %>
test:
  primary:
    database: myapp_test<%= ENV["TEST_ENV_NUMBER"] %>
YAML

patch_database_yml 2>/dev/null
content=$(cat config/database.yml)
# Should be unchanged
assert_true "already patched is no-op" echo "$content" | grep -q 'DEV_ENV_NUMBER'

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

  # Dev databases should have DEV_ENV_NUMBER
  dev_count=$(echo "$content" | grep -c 'DEV_ENV_NUMBER' || true)
  assert_equal "dev databases patched (2 entries)" "2" "$dev_count"

  # Test databases should have TEST_ENV_NUMBER
  test_count=$(echo "$content" | grep -c 'TEST_ENV_NUMBER' || true)
  assert_equal "test databases patched (2 entries)" "2" "$test_count"

  # Production should NOT be touched
  prod_lines=$(echo "$content" | grep 'production' | grep 'ENV_NUMBER' || true)
  assert_equal "production not patched" "" "$prod_lines"

  # Specific line checks
  dev_match=$(echo "$content" | grep 'myapp_development<%= ENV\["DEV_ENV_NUMBER"\] %>' || true)
  assert_true "dev primary patched" [ -n "$dev_match" ]
  test_match=$(echo "$content" | grep 'myapp_test<%= ENV\["TEST_ENV_NUMBER"\] %>' || true)
  assert_true "test primary patched" [ -n "$test_match" ]
fi

report "db.sh"
