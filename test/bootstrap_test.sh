#!/bin/sh
# Integration tests for workspace bootstrap ordering and database safety.

cd "$(dirname "$0")"
. ./test_helper.sh

run_bootstrap() {
  CONDUCTOR_ROOT_PATH="$1" CONDUCTOR_WORKSPACE_NAME="$2" \
    WORKSPACE_TEST_LOG="$3" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
}

run_superconductor_bootstrap() {
  SUPERCONDUCTOR_ROOT_PATH="$1" SUPERCONDUCTOR_WORKSPACE_NAME="$2" \
    WORKSPACE_TEST_LOG="$3" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
}

run_superset_bootstrap() {
  SUPERSET_ROOT_PATH="$1" SUPERSET_WORKSPACE_NAME="$2" \
    WORKSPACE_TEST_LOG="$3" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
}

make_bootstrap_app() {
  app_dir=$(create_fake_app "$1")
  root_dir=$(create_fake_root "$1")
  mkdir -p "$app_dir/config"
  printf '%s\n' "$app_dir|$root_dir"
}

install_suffix_logging_lifecycle() {
  cat > config/database.yml <<'YAML'
development:
  database: provider_development
test:
  database: provider_test
YAML
  cat > bin/setup <<'SCRIPT'
#!/bin/sh
printf 'setup:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
SCRIPT
  cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf 'rails:%s:%s:%s\n' "$RAILS_ENV" "$WORKSPACE_DB_SUFFIX" "$*" >> "$WORKSPACE_TEST_LOG"
SCRIPT
  chmod +x bin/setup bin/rails
}

# A project can materialize database.yml before its ordinary setup script. The
# CLI patches it before setup, then uses non-destructive db:prepare afterward.
paths=$(make_bootstrap_app "pre-setup-db")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/pre-setup-db.log"
cd "$app_dir"
cat > bin/workspace-database-hook <<'SCRIPT'
#!/bin/sh
printf 'database-hook:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
cat > config/database.yml <<'YAML'
development:
  database: app_development
test:
  database: app_test
YAML
SCRIPT
cat > bin/setup <<'SCRIPT'
#!/bin/sh
grep -q WORKSPACE_DB_SUFFIX config/database.yml || exit 1
printf 'setup:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
printf 'seeded-data\n' > .setup-data
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf 'rails:%s:%s:%s\n' "$RAILS_ENV" "$WORKSPACE_DB_SUFFIX" "$*" >> "$WORKSPACE_TEST_LOG"
[ "$1" != "db:schema:load" ] || rm -f .setup-data
exit 0
SCRIPT
cat > bin/workspace-seed <<'SCRIPT'
#!/bin/sh
printf 'seed:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
SCRIPT
chmod +x bin/workspace-database-hook bin/setup bin/rails bin/workspace-seed

assert_true "bootstrap with pre-setup database hook succeeds" run_bootstrap "$root_dir" "feature-one" "$log"
assert_equal "database hook runs before setup" "database-hook:_feature-one" "$(sed -n '1p' "$log")"
assert_equal "setup sees isolated suffix" "setup:_feature-one" "$(sed -n '2p' "$log")"
assert_true "development database uses db:prepare" grep -q '^rails:development:_feature-one:db:prepare$' "$log"
assert_true "test database uses db:prepare" grep -q '^rails:test:_feature-one:db:prepare$' "$log"
assert_false "bootstrap never schema-loads after setup" grep -q 'db:schema:load' "$log"
assert_true "data created by setup is preserved" grep -q 'seeded-data' .setup-data
assert_true "database.yml is patched before setup" grep -q WORKSPACE_DB_SUFFIX config/database.yml

# Superconductor and Superset use the same successful lifecycle while retaining
# their provider-specific identity inputs. Their sanitized names must propagate
# exactly through project setup and both database preparation environments.
paths=$(make_bootstrap_app "superconductor-lifecycle")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/superconductor-lifecycle.log"
cd "$app_dir"
install_suffix_logging_lifecycle

assert_true "Superconductor bootstrap succeeds" run_superconductor_bootstrap "$root_dir" "feature/alpha@2" "$log"
assert_equal "Superconductor setup receives exact suffix" "setup:_feature-alpha-2" "$(sed -n '1p' "$log")"
assert_true "Superconductor development preparation receives exact suffix" grep -q '^rails:development:_feature-alpha-2:db:prepare$' "$log"
assert_true "Superconductor test preparation receives exact suffix" grep -q '^rails:test:_feature-alpha-2:db:prepare$' "$log"

paths=$(make_bootstrap_app "superset-lifecycle")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/superset-lifecycle.log"
cd "$app_dir"
install_suffix_logging_lifecycle

assert_true "Superset bootstrap succeeds" run_superset_bootstrap "$root_dir" "review/blue sky" "$log"
assert_equal "Superset setup receives exact suffix" "setup:_review-blue-sky" "$(sed -n '1p' "$log")"
assert_true "Superset development preparation receives exact suffix" grep -q '^rails:development:_review-blue-sky:db:prepare$' "$log"
assert_true "Superset test preparation receives exact suffix" grep -q '^rails:test:_review-blue-sky:db:prepare$' "$log"

# Existing projects whose setup script creates database.yml remain supported:
# the CLI patches the generated file before preparing the databases.
paths=$(make_bootstrap_app "setup-creates-db")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/setup-creates-db.log"
cd "$app_dir"
cat > bin/setup <<'SCRIPT'
#!/bin/sh
printf 'setup:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
cat > config/database.yml <<'YAML'
development:
  database: generated_development
test:
  database: generated_test
YAML
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
grep -q WORKSPACE_DB_SUFFIX config/database.yml || exit 1
printf 'rails:%s:%s\n' "$RAILS_ENV" "$*" >> "$WORKSPACE_TEST_LOG"
SCRIPT
chmod +x bin/setup bin/rails

assert_true "bootstrap supports database.yml generated by setup" run_bootstrap "$root_dir" "generated-db" "$log"
assert_true "generated database.yml is isolated" grep -q WORKSPACE_DB_SUFFIX config/database.yml
assert_equal "setup runs before generated config can be patched" "setup:_generated-db" "$(sed -n '1p' "$log")"
assert_true "generated development config is prepared" grep -q '^rails:development:db:prepare$' "$log"

# Projects without setup scripts still get their existing config patched and
# both databases prepared.
paths=$(make_bootstrap_app "no-setup")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/no-setup.log"
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  database: no_setup_development
test:
  database: no_setup_test
YAML
cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf '%s:%s\n' "$RAILS_ENV" "$*" >> "$WORKSPACE_TEST_LOG"
SCRIPT
chmod +x bin/rails

assert_true "bootstrap without setup script succeeds" run_bootstrap "$root_dir" "no-setup" "$log"
assert_true "no-setup config is isolated" grep -q WORKSPACE_DB_SUFFIX config/database.yml
assert_true "no-setup development database is prepared" grep -q '^development:db:prepare$' "$log"

# Database failures must fail bootstrap and must not print a success result.
paths=$(make_bootstrap_app "prepare-failure")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/prepare-failure.log"
output="$TEST_TMP/prepare-failure.out"
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  database: failure_development
test:
  database: failure_test
YAML
cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 1
SCRIPT
chmod +x bin/rails

assert_false "bootstrap reports db:prepare failure" env CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="prepare-failure" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >"$output" 2>&1
assert_false "failed bootstrap does not report database ready" grep -q 'database ready' "$output"
assert_false "failed bootstrap does not report setup complete" grep -q 'Setup complete' "$output"

# The manager's root/default identity remains a setup-only path, while a
# workspace name that sanitizes to empty is rejected instead of becoming root.
paths=$(make_bootstrap_app "default-root")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/default-root.log"
cd "$app_dir"
cat > bin/setup <<'SCRIPT'
#!/bin/sh
printf 'root-setup:%s\n' "${WORKSPACE_DB_SUFFIX:-unset}" > "$WORKSPACE_TEST_LOG"
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
touch .rails-called
SCRIPT
chmod +x bin/setup bin/rails
assert_true "manager default remains a root setup" run_bootstrap "$root_dir" "default" "$log"
assert_equal "root setup has no isolated suffix" "root-setup:unset" "$(cat "$log")"
assert_false "root setup does not prepare isolated databases" [ -f .rails-called ]

paths=$(make_bootstrap_app "invalid-name")
app_dir=${paths%%|*}
root_dir=${paths#*|}
cd "$app_dir"
cat > bin/setup <<'SCRIPT'
#!/bin/sh
touch .setup-called
SCRIPT
chmod +x bin/setup
assert_false "empty sanitized workspace identity is rejected" env SUPERSET_ROOT_PATH="$root_dir" SUPERSET_WORKSPACE_NAME="///" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_false "invalid identity is rejected before setup" [ -f .setup-called ]

report "bootstrap lifecycle"
