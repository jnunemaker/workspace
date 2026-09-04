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

output_has() {
  printf '%s\n' "$1" | grep -q "$2"
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

help_output=$(sh "$WORKSPACE_HOME/lib/bootstrap.sh" --help)
assert_true "bootstrap help documents dedicated setup hook" output_has "$help_output" 'workspace setup hook'
assert_true "bootstrap help documents legacy setup fallback" output_has "$help_output" 'legacy setup fallback'
assert_true "bootstrap help documents the database suffix" output_has "$help_output" 'database hook can read WORKSPACE_DB_SUFFIX'
assert_true "bootstrap help limits the root path to the database hook" output_has "$help_output" 'WORKSPACE_ROOT_PATH, but only while the hook runs'
assert_true "bootstrap help says bin/update is never run" output_has "$help_output" 'never runs bin/update'

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

# A managed sibling's dedicated setup hook runs after shared files and the
# suffix exist, and replaces (rather than supplements) ordinary bin/setup.
paths=$(make_bootstrap_app "dedicated-setup-hook")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/dedicated-setup-hook.log"
cd "$app_dir"
cat > "$root_dir/.env" <<'ENV'
shared=true
WORKSPACE_NAME=wrong-dotenv-identity
WORKSPACE_PROVIDER=wrong-dotenv-provider
WORKSPACE_ROOT_PATH=/wrong/dotenv/root
ENV
cat > config/database.yml <<'YAML'
development:
  database: hook_development
test:
  database: hook_test
YAML
cat > bin/workspace-database-hook <<'SCRIPT'
#!/bin/sh
printf 'database:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
SCRIPT
cat > bin/workspace-setup-hook <<'SCRIPT'
#!/bin/sh
[ -L .env ] || exit 1
[ "${shared:-}" = "true" ] || exit 1
[ "${WORKSPACE_ROOT_PATH+x}" != "x" ] || exit 1
printf 'workspace-setup:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
SCRIPT
cat > bin/setup <<'SCRIPT'
#!/bin/sh
touch .ordinary-setup-called
SCRIPT
cat > bin/update <<'SCRIPT'
#!/bin/sh
touch .update-called
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf 'rails:%s:%s\n' "$RAILS_ENV" "$*" >> "$WORKSPACE_TEST_LOG"
SCRIPT
cat > bin/workspace-seed <<'SCRIPT'
#!/bin/sh
printf 'seed:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
SCRIPT
cat > bin/workspace-bootstrap-hook <<'SCRIPT'
#!/bin/sh
printf 'bootstrap:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
SCRIPT
chmod +x bin/workspace-database-hook bin/workspace-setup-hook bin/setup bin/update bin/rails bin/workspace-seed bin/workspace-bootstrap-hook

assert_true "dedicated workspace setup hook succeeds" run_bootstrap "$root_dir" "dedicated-hook" "$log"
assert_equal "dedicated lifecycle has explicit ordering" "database:_dedicated-hook
workspace-setup:_dedicated-hook
rails:development:db:prepare
rails:test:db:prepare
seed:_dedicated-hook
bootstrap:_dedicated-hook" "$(cat "$log")"
assert_false "dedicated hook prevents ordinary bin/setup" [ -f .ordinary-setup-called ]
assert_false "workspace lifecycle never invokes bin/update" [ -f .update-called ]

# A source-only environment hook can activate a project runtime without
# Workspace knowing which toolchain manager produced it. Its PATH reaches the
# dedicated setup hook and Workspace's own Rails database preparation.
paths=$(make_bootstrap_app "environment-toolchain")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/environment-toolchain.log"
toolchain_bin="$TEST_TMP/environment-toolchain-bin"
mkdir -p "$toolchain_bin"
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  database: environment_development
test:
  database: environment_test
YAML
cat > bin/workspace-environment-hook <<'SCRIPT'
PATH="$WORKSPACE_TEST_TOOLCHAIN_BIN:$PATH"
export PATH
printf 'environment:%s:%s:%s\n' "$WORKSPACE_PROVIDER" "$WORKSPACE_ROOT_PATH" "$WORKSPACE_NAME" >> "$WORKSPACE_TEST_LOG"
WORKSPACE_PROVIDER=wrong-hook-provider
WORKSPACE_ROOT_PATH=/wrong/hook/root
WORKSPACE_NAME=wrong-hook-name
WORKSPACE_DB_SUFFIX=_wrong-hook-suffix
CONDUCTOR_ROOT_PATH=/wrong/raw/root
CONDUCTOR_WORKSPACE_NAME=wrong-raw-name
CONDUCTOR_PORT=1
export WORKSPACE_PROVIDER WORKSPACE_ROOT_PATH WORKSPACE_NAME WORKSPACE_DB_SUFFIX
export CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME CONDUCTOR_PORT
SCRIPT
cat > "$toolchain_bin/workspace-test-runtime" <<'SCRIPT'
#!/bin/sh
script="$1"
shift
exec /bin/sh "$script" "$@"
SCRIPT
cat > bin/workspace-setup-hook <<'SCRIPT'
#!/usr/bin/env workspace-test-runtime
printf 'setup:%s:%s:%s:%s:%s:%s:%s\n' "$WORKSPACE_PROVIDER" "$WORKSPACE_ROOT_PATH" "$WORKSPACE_NAME" "$WORKSPACE_DB_SUFFIX" "$CONDUCTOR_ROOT_PATH" "$CONDUCTOR_WORKSPACE_NAME" "$CONDUCTOR_PORT" >> "$WORKSPACE_TEST_LOG"
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/usr/bin/env workspace-test-runtime
printf 'rails:%s:%s:%s\n' "$RAILS_ENV" "$WORKSPACE_DB_SUFFIX" "$*" >> "$WORKSPACE_TEST_LOG"
SCRIPT
chmod +x "$toolchain_bin/workspace-test-runtime" bin/workspace-setup-hook bin/rails

assert_true "environment hook supplies managed bootstrap toolchain" env \
  PATH="/usr/bin:/bin" CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="environment-workspace" CONDUCTOR_PORT=51000 \
  WORKSPACE_TEST_TOOLCHAIN_BIN="$toolchain_bin" WORKSPACE_TEST_LOG="$log" \
  /bin/sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "environment hook receives resolved provider state" \
  "environment:conductor:$root_dir:environment-workspace" "$(sed -n '1p' "$log")"
assert_equal "environment hook cannot replace provider lifecycle state" \
  "setup:conductor:$root_dir:environment-workspace:_environment-workspace:$root_dir:environment-workspace:51000" \
  "$(sed -n '2p' "$log")"
assert_equal "environment toolchain reaches Rails preparation" \
  "rails:development:_environment-workspace:db:prepare
rails:test:_environment-workspace:db:prepare" "$(sed -n '3,4p' "$log")"
assert_false "sourced environment hook does not need executable mode" [ -x bin/workspace-environment-hook ]

# The same source point applies to root/default bootstrap before ordinary
# project setup, while retaining the root's unsuffixed database contract.
paths=$(make_bootstrap_app "root-environment-toolchain")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/root-environment-toolchain.log"
cd "$app_dir"
cat > bin/workspace-environment-hook <<'SCRIPT'
PATH="$WORKSPACE_TEST_TOOLCHAIN_BIN:$PATH"
export PATH
printf 'root-environment:%s:%s\n' "$WORKSPACE_PROVIDER" "$WORKSPACE_NAME" >> "$WORKSPACE_TEST_LOG"
WORKSPACE_DB_SUFFIX=_wrong-hook-suffix
WORKSPACE_REGISTERED_PORT=51900
export WORKSPACE_DB_SUFFIX WORKSPACE_REGISTERED_PORT
SCRIPT
cat > bin/setup <<'SCRIPT'
#!/usr/bin/env workspace-test-runtime
if env | grep -q '^WORKSPACE_DB_SUFFIX='; then
  printf 'root-setup:set:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
else
  printf 'root-setup:unset\n' >> "$WORKSPACE_TEST_LOG"
fi
if env | grep -q '^WORKSPACE_REGISTERED_PORT='; then
  printf 'registered-port:set:%s\n' "$WORKSPACE_REGISTERED_PORT" >> "$WORKSPACE_TEST_LOG"
else
  printf 'registered-port:unset\n' >> "$WORKSPACE_TEST_LOG"
fi
SCRIPT
chmod +x bin/setup

assert_true "environment hook supplies root bootstrap toolchain" env \
  PATH="/usr/bin:/bin" CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="default" \
  WORKSPACE_TEST_TOOLCHAIN_BIN="$toolchain_bin" WORKSPACE_TEST_LOG="$log" \
  /bin/sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "root environment hook runs before ordinary setup" \
  "root-environment:conductor:
root-setup:unset
registered-port:unset" "$(cat "$log")"

# A failed sourced environment hook is a hard boundary: partial PATH changes
# do not permit setup or database work to continue.
paths=$(make_bootstrap_app "failing-environment-hook")
app_dir=${paths%%|*}
root_dir=${paths#*|}
cd "$app_dir"
cat > bin/workspace-environment-hook <<'SCRIPT'
PATH="$WORKSPACE_TEST_TOOLCHAIN_BIN:$PATH"
export PATH
return 23
SCRIPT
cat > bin/workspace-setup-hook <<'SCRIPT'
#!/bin/sh
touch .workspace-setup-called
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
touch .rails-called
SCRIPT
chmod +x bin/workspace-setup-hook bin/rails

assert_false "failing environment hook fails bootstrap" env \
  PATH="/usr/bin:/bin" CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="failing-environment" \
  WORKSPACE_TEST_TOOLCHAIN_BIN="$toolchain_bin" \
  /bin/sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_false "failed environment hook prevents setup" [ -e .workspace-setup-called ]
assert_false "failed environment hook prevents Rails preparation" [ -e .rails-called ]

# A failing dedicated hook is a hard lifecycle boundary. Nothing after it may
# prepare databases, register the workspace, seed data, or report success.
paths=$(make_bootstrap_app "failing-setup-hook")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/failing-setup-hook.log"
output="$TEST_TMP/failing-setup-hook.out"
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  database: hook_failure_development
test:
  database: hook_failure_test
YAML
cat > bin/workspace-setup-hook <<'SCRIPT'
#!/bin/sh
printf 'workspace-setup:%s\n' "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_LOG"
exit 42
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
touch .rails-called
SCRIPT
cat > bin/workspace-seed <<'SCRIPT'
#!/bin/sh
touch .seed-called
SCRIPT
cat > bin/workspace-bootstrap-hook <<'SCRIPT'
#!/bin/sh
touch .bootstrap-hook-called
SCRIPT
chmod +x bin/workspace-setup-hook bin/rails bin/workspace-seed bin/workspace-bootstrap-hook

assert_false "failing workspace setup hook fails bootstrap" env CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="failing-hook" WORKSPACE_TEST_LOG="$log" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >"$output" 2>&1
assert_equal "failing setup hook runs with isolated suffix" "workspace-setup:_failing-hook" "$(cat "$log")"
assert_false "failed setup hook prevents database preparation" [ -f .rails-called ]
assert_false "failed setup hook prevents workspace registration" [ -f .workspace ]
assert_false "failed setup hook prevents seeding" [ -f .seed-called ]
assert_false "failed setup hook prevents bootstrap hook" [ -f .bootstrap-hook-called ]
assert_false "failed setup hook does not report setup complete" grep -q 'Setup complete' "$output"

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

# Markerless Superset adoption must retain the provider's historical 45-character
# identity rather than re-keying the workspace to Workspace's newer limit.
paths=$(make_bootstrap_app "superset-long-identity")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/superset-long-identity.log"
cd "$app_dir"
install_suffix_logging_lifecycle
superset_identity="123456789012345678901234567890123456789012345"

assert_true "45-character Superset bootstrap succeeds" run_superset_bootstrap "$root_dir" "$superset_identity" "$log"
assert_equal "45-character Superset identity reaches setup" "setup:_${superset_identity}" "$(sed -n '1p' "$log")"
assert_true "45-character Superset identity reaches database preparation" grep -q "^rails:development:_${superset_identity}:db:prepare$" "$log"
assert_equal "45-character Superset identity is pinned unchanged" "$superset_identity" "$(cat .workspace)"

# Existing Conductor-family worktrees already pin their database identity in
# .conductor-workspace. That marker wins over both provider drift and a stale
# Workspace marker, including identities longer than Workspace's own default.
paths=$(make_bootstrap_app "legacy-conductor-identity")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/legacy-conductor-identity.log"
cd "$app_dir"
install_suffix_logging_lifecycle
legacy_identity="123456789012345678901234567890123456789012345"
printf '%s' "$legacy_identity" > .conductor-workspace
printf '%s' "wrong-workspace-name" > .workspace

assert_true "legacy Conductor identity bootstrap succeeds" run_superset_bootstrap "$root_dir" "renamed/provider-workspace" "$log"
assert_equal "legacy Conductor identity reaches setup" "setup:_${legacy_identity}" "$(sed -n '1p' "$log")"
assert_true "legacy Conductor identity reaches development preparation" grep -q "^rails:development:_${legacy_identity}:db:prepare$" "$log"
assert_equal "Workspace marker is synchronized to legacy identity" "$legacy_identity" "$(cat .workspace)"

# A project identity hook supplies an established database key on first use.
# Once bootstrap writes .workspace, repeated bootstrap never calls the hook or
# follows a renamed provider identity.
paths=$(make_bootstrap_app "identity-hook-bootstrap")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/identity-hook-bootstrap.log"
hook_log="$TEST_TMP/identity-hook-calls.log"
cd "$app_dir"
install_suffix_logging_lifecycle
cat > bin/setup <<'SCRIPT'
#!/bin/sh
printf 'setup:%s:%s\n' "$WORKSPACE_DB_SUFFIX" "${WORKSPACE_ROOT_PATH-unset}" >> "$WORKSPACE_TEST_LOG"
SCRIPT
cat > "$root_dir/config/database.yml" <<'YAML'
development:
  database: root_development
test:
  database: root_test
YAML
cat > bin/workspace-database-hook <<'SCRIPT'
#!/bin/sh
printf 'database:%s:%s\n' "$WORKSPACE_DB_SUFFIX" "$WORKSPACE_ROOT_PATH" >> "$WORKSPACE_TEST_LOG"
cp "$WORKSPACE_ROOT_PATH/config/database.yml" config/database.yml
SCRIPT
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
printf 'called\n' >> "$WORKSPACE_IDENTITY_HOOK_LOG"
printf 'identity:%s\n' "$WORKSPACE_ROOT_PATH" >> "$WORKSPACE_TEST_LOG"
printf '%s' "stable-worktree-id"
SCRIPT
chmod +x bin/workspace-database-hook bin/workspace-identity-hook

WORKSPACE_IDENTITY_HOOK_LOG="$hook_log" \
  assert_true "first identity-hook bootstrap succeeds" run_bootstrap "$root_dir" "display-name" "$log"
assert_equal "identity hook pins first bootstrap" "stable-worktree-id" "$(cat .workspace)"
assert_equal "identity hook called once" "1" "$(wc -l < "$hook_log" | tr -d ' ')"
assert_equal "identity hook receives root" "identity:$root_dir" "$(sed -n '1p' "$log")"
assert_equal "first database hook receives root and pinned suffix" "database:_stable-worktree-id:$root_dir" "$(sed -n '2p' "$log")"
assert_equal "first setup does not inherit root path" "setup:_stable-worktree-id:unset" "$(sed -n '3p' "$log")"

: > "$log"
WORKSPACE_IDENTITY_HOOK_LOG="$hook_log" \
  assert_true "repeated identity-hook bootstrap succeeds" run_bootstrap "$root_dir" "renamed-display-name" "$log"
assert_equal "repeated database hook receives root and pinned suffix" "database:_stable-worktree-id:$root_dir" "$(sed -n '1p' "$log")"
assert_equal "repeated bootstrap keeps pinned suffix without root path" "setup:_stable-worktree-id:unset" "$(sed -n '2p' "$log")"
assert_equal "pinned marker bypasses identity hook" "1" "$(wc -l < "$hook_log" | tr -d ' ')"

# A provider may supply a workspace name without a root checkout. The identity
# hook keeps its empty-value contract while the database hook sees no variable.
paths=$(make_bootstrap_app "database-hook-without-root")
app_dir=${paths%%|*}
log="$TEST_TMP/database-hook-without-root.log"
cd "$app_dir"
install_suffix_logging_lifecycle
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
printf 'identity:%s:%s\n' "${WORKSPACE_ROOT_PATH+x}" "${WORKSPACE_ROOT_PATH-}" >> "$WORKSPACE_TEST_LOG"
printf '%s' "rootless-identity"
SCRIPT
cat > bin/workspace-database-hook <<'SCRIPT'
#!/bin/sh
printf 'database:%s\n' "${WORKSPACE_ROOT_PATH-unset}" >> "$WORKSPACE_TEST_LOG"
SCRIPT
chmod +x bin/workspace-identity-hook bin/workspace-database-hook

WORKSPACE_ROOT_PATH="/stale/exported/root" \
  CONDUCTOR_ROOT_PATH="" CONDUCTOR_WORKSPACE_NAME="rootless-provider" \
  WORKSPACE_TEST_LOG="$log" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
rootless_bootstrap_status=$?
assert_equal "rootless provider bootstrap succeeds" "0" "$rootless_bootstrap_status"
assert_equal "identity hook retains its set-empty root contract" "identity:x:" "$(sed -n '1p' "$log")"
assert_equal "database hook receives no empty root variable" "database:unset" "$(sed -n '2p' "$log")"

# A provider-supplied path must name a directory before the database hook can
# use it as an original checkout.
paths=$(make_bootstrap_app "database-hook-with-stale-root")
app_dir=${paths%%|*}
log="$TEST_TMP/database-hook-with-stale-root.log"
cd "$app_dir"
install_suffix_logging_lifecycle
cat > bin/workspace-database-hook <<'SCRIPT'
#!/bin/sh
printf 'database:%s\n' "${WORKSPACE_ROOT_PATH-unset}" >> "$WORKSPACE_TEST_LOG"
SCRIPT
chmod +x bin/workspace-database-hook

assert_true "stale-root provider bootstrap succeeds" run_bootstrap \
  "$TEST_TMP/missing-root" "stale-root-provider" "$log"
assert_equal "database hook does not receive a stale root path" "database:unset" "$(sed -n '1p' "$log")"

# Invalid stable identity fails before project setup or database preparation.
paths=$(make_bootstrap_app "invalid-stable-identity")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/invalid-stable-identity.log"
cd "$app_dir"
install_suffix_logging_lifecycle
printf 'first\nsecond\n' > .workspace

assert_false "invalid stable identity aborts bootstrap" run_bootstrap "$root_dir" "provider-name" "$log"
assert_false "invalid stable identity prevents setup" [ -f "$log" ]

# A non-regular marker cannot be synchronized atomically. Reject it during
# identity resolution, before project setup or database preparation begins.
paths=$(make_bootstrap_app "directory-stable-identity")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/directory-stable-identity.log"
cd "$app_dir"
install_suffix_logging_lifecycle
mkdir .workspace

assert_false "directory stable identity aborts bootstrap" run_bootstrap "$root_dir" "provider-name" "$log"
assert_false "directory stable identity prevents setup and database preparation" [ -f "$log" ]
assert_equal "directory stable identity is not modified" "" "$(find .workspace -mindepth 1 -maxdepth 1 -print)"

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
cat > bin/workspace-setup-hook <<'SCRIPT'
#!/bin/sh
touch .workspace-setup-called
SCRIPT
cat > bin/update <<'SCRIPT'
#!/bin/sh
touch .update-called
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
touch .rails-called
SCRIPT
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
touch .identity-hook-called
printf '%s' "must-not-isolate-root"
SCRIPT
chmod +x bin/setup bin/workspace-setup-hook bin/update bin/rails bin/workspace-identity-hook
assert_true "manager default remains a root setup" run_bootstrap "$root_dir" "default" "$log"
assert_equal "root setup has no isolated suffix" "root-setup:unset" "$(cat "$log")"
assert_false "root setup ignores identity hook" [ -f .identity-hook-called ]
assert_false "root setup does not persist isolated identity" [ -e .workspace ]
assert_false "root setup does not prepare isolated databases" [ -f .rails-called ]
assert_false "root setup ignores managed workspace setup hook" [ -f .workspace-setup-called ]
assert_false "root setup never invokes bin/update" [ -f .update-called ]

# Shared tracked files remain branch-owned instead of becoming root symlinks.
paths=$(make_bootstrap_app "tracked-shared-file")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/tracked-shared-file.log"
cd "$app_dir"
printf 'ruby 3.4.1\n' > .tool-versions
printf 'ruby 3.3.0\n' > "$root_dir/.tool-versions"
git init -q
git add .tool-versions
cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x bin/rails

assert_true "bootstrap preserves tracked shared file" run_bootstrap "$root_dir" "tracked-file" "$log"
assert_false "tracked shared file is not a symlink" [ -L .tool-versions ]
assert_equal "tracked shared file keeps branch contents" "ruby 3.4.1" "$(cat .tool-versions)"

# Shared directories with tracked descendants are branch-owned too. Preserve
# the complete workspace directory, including modifications made after the
# tracked file entered the index, instead of replacing it with the root copy.
paths=$(make_bootstrap_app "tracked-shared-directories")
app_dir=${paths%%|*}
root_dir=${paths#*|}
output="$TEST_TMP/tracked-shared-directories.out"
cd "$app_dir"
mkdir -p storage .bundle "$root_dir/storage" "$root_dir/.bundle"
printf 'workspace storage committed\n' > storage/.keep
printf 'workspace bundle committed\n' > .bundle/config
git init -q
git add storage/.keep .bundle/config
printf 'workspace storage modified\n' > storage/.keep
printf 'workspace bundle modified\n' > .bundle/config
printf 'root storage\n' > "$root_dir/storage/.keep"
printf 'root bundle\n' > "$root_dir/.bundle/config"
cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x bin/rails

assert_true "bootstrap preserves tracked shared directories" env CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="tracked-directories" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >"$output" 2>&1
assert_false "tracked storage directory is not a symlink" [ -L storage ]
assert_false "tracked bundle directory is not a symlink" [ -L .bundle ]
assert_equal "tracked storage keeps local modification" "workspace storage modified" "$(cat storage/.keep)"
assert_equal "tracked bundle keeps local modification" "workspace bundle modified" "$(cat .bundle/config)"
assert_true "tracked storage skip is explained" grep -q 'storage contains tracked files.*keeping workspace copy' "$output"
assert_true "tracked bundle skip is explained" grep -q '\.bundle contains tracked files.*keeping workspace copy' "$output"

# Tracked path ownership applies even when the shared-directory name is a
# symlink or regular file rather than a directory.
paths=$(make_bootstrap_app "tracked-shared-path-types")
app_dir=${paths%%|*}
root_dir=${paths#*|}
output="$TEST_TMP/tracked-shared-path-types.out"
cd "$app_dir"
mkdir -p linked-storage "$root_dir/storage" "$root_dir/.bundle"
printf 'workspace bundle file\n' > .bundle
ln -s linked-storage storage
git init -q
git add .bundle storage
printf 'root storage\n' > "$root_dir/storage/shared"
printf 'root bundle\n' > "$root_dir/.bundle/shared"
cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x bin/rails

assert_true "bootstrap preserves tracked shared path types" env CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="tracked-path-types" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >"$output" 2>&1
assert_equal "tracked storage symlink keeps its branch target" "linked-storage" "$(readlink storage)"
assert_false "tracked bundle regular file is not replaced" [ -L .bundle ]
assert_equal "tracked bundle regular file keeps branch contents" "workspace bundle file" "$(cat .bundle)"

# Directories containing only untracked workspace data retain the historical
# behavior: Workspace replaces them with links to the root checkout.
paths=$(make_bootstrap_app "untracked-shared-directories")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/untracked-shared-directories.log"
cd "$app_dir"
mkdir -p storage .bundle "$root_dir/storage" "$root_dir/.bundle"
printf 'workspace only\n' > storage/local
printf 'workspace only\n' > .bundle/local
printf 'root storage\n' > "$root_dir/storage/shared"
printf 'root bundle\n' > "$root_dir/.bundle/shared"
cat > bin/rails <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x bin/rails

assert_true "bootstrap links untracked shared directories" run_bootstrap "$root_dir" "untracked-directories" "$log"
assert_true "untracked storage becomes a symlink" [ -L storage ]
assert_true "untracked bundle becomes a symlink" [ -L .bundle ]
assert_equal "storage links to root directory" "$root_dir/storage" "$(readlink storage)"
assert_equal "bundle links to root directory" "$root_dir/.bundle" "$(readlink .bundle)"

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
