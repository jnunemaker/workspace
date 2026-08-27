#!/bin/sh
# Integration tests for dotenv precedence and displayed application URLs.

cd "$(dirname "$0")"
. ./test_helper.sh

fake_bin="$TEST_TMP/run-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/lsof" <<'SCRIPT'
#!/bin/sh
exit 1
SCRIPT
chmod +x "$fake_bin/lsof"

# Help must stay available without evaluating project state or a failing .env.
help_app=$(create_fake_app "run-help")
cd "$help_app"
cat > .env <<'ENV'
false
ENV
help_output="$TEST_TMP/run-help.out"
assert_true "run help succeeds without sourcing a failing dotenv" sh "$WORKSPACE_HOME/lib/run.sh" --help >"$help_output" 2>&1
assert_true "run help prints usage" grep -q '^Usage: workspace run$' "$help_output"

make_run_app() {
  app_dir=$(create_fake_app "$1")
  root_dir=$(create_fake_root "$1")
  mkdir -p "$app_dir/bin"
  cat > "$app_dir/bin/foreman" <<'SCRIPT'
#!/bin/sh
{
  printf 'DOTENV_ONLY=%s\n' "$DOTENV_ONLY"
  printf 'EXPORTED_VALUE=%s\n' "$EXPORTED_VALUE"
  printf 'HOOK_VALUE=%s\n' "$HOOK_VALUE"
  printf 'PORT=%s\n' "$PORT"
  printf 'WORKSPACE_DB_SUFFIX=%s\n' "$WORKSPACE_DB_SUFFIX"
  env | grep '^_dotenv_' || true
  printf 'ARGS=%s\n' "$*"
} > "$WORKSPACE_TEST_RUN_LOG"
SCRIPT
  chmod +x "$app_dir/bin/foreman"
  printf '%s\n' "$app_dir|$root_dir"
}

# The linked .env supplies defaults. Existing exported values, manager ports,
# and run-hook exports win when names overlap.
paths=$(make_run_app "dotenv")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/dotenv.log"
output="$TEST_TMP/dotenv.out"
cat > "$root_dir/.env" <<'ENV'
DOTENV_ONLY=from-dotenv
EXPORTED_VALUE=from-dotenv
HOOK_VALUE=from-dotenv
PORT=9999
ENV
ln -s "$root_dir/.env" "$app_dir/.env"
cat > "$app_dir/bin/workspace-run-hook" <<'SCRIPT'
#!/bin/sh
export HOOK_VALUE=from-hook
WORKSPACE_APP_URL=https://app.example.test/workspace
SCRIPT
chmod +x "$app_dir/bin/workspace-run-hook"

cd "$app_dir"
PATH="$fake_bin:$PATH" EXPORTED_VALUE=from-manager CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="dotenv-workspace" CONDUCTOR_PORT=51230 \
  WORKSPACE_TEST_RUN_LOG="$log" sh "$WORKSPACE_HOME/lib/run.sh" >"$output" 2>&1

assert_true "linked dotenv value reaches dev processes" grep -q '^DOTENV_ONLY=from-dotenv$' "$log"
assert_true "exported value takes precedence over dotenv" grep -q '^EXPORTED_VALUE=from-manager$' "$log"
assert_true "run-hook export takes precedence over dotenv" grep -q '^HOOK_VALUE=from-hook$' "$log"
assert_true "manager port takes precedence over dotenv" grep -q '^PORT=51230$' "$log"
assert_true "workspace suffix reaches dev processes" grep -q '^WORKSPACE_DB_SUFFIX=_dotenv-workspace$' "$log"
assert_false "dotenv helper variables do not reach dev processes" grep -q '^_dotenv_' "$log"
assert_true "foreman dotenv reloading remains disabled after shell import" grep -q 'ARGS=start -f Procfile.dev --env /dev/null' "$log"
assert_true "run hook overrides displayed application URL" grep -q 'https://app.example.test/workspace' "$output"

# A dotenv Workspace override participates in the same resolution used by
# info, before run registers or exports its port block.
paths=$(make_run_app "dotenv-workspace-port")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/dotenv-workspace-port.log"
cat > "$app_dir/.env" <<'ENV'
WORKSPACE_PORT=51500
WORKSPACE_NAME=wrong-dotenv-identity
WORKSPACE_PROVIDER=wrong-dotenv-provider
WORKSPACE_ROOT_PATH=/wrong/dotenv/root
ENV
printf '%s' "stable-dotenv-identity" > "$app_dir/.conductor-workspace"
cd "$app_dir"
info_output=$(CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="renamed-dotenv-workspace" \
  sh "$WORKSPACE_HOME/lib/info.sh")
PATH="$fake_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="renamed-dotenv-workspace" \
  WORKSPACE_TEST_RUN_LOG="$log" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_true "info resolves dotenv workspace port" sh -c 'printf "%s\n" "$1" | grep -q "^Ports: 51500-51509$"' sh "$info_output"
assert_true "run uses the same dotenv workspace port" grep -q '^PORT=51500$' "$log"
assert_true "info preserves marker identity across dotenv loading" sh -c 'printf "%s\n" "$1" | grep -q "^Workspace: stable-dotenv-identity$"' sh "$info_output"
assert_true "info preserves provider across dotenv loading" sh -c 'printf "%s\n" "$1" | grep -q "^Provider: conductor$"' sh "$info_output"
assert_true "info preserves root across dotenv loading" sh -c 'printf "%s\n" "$1" | grep -q "^Root: $2$"' sh "$info_output" "$root_dir"
assert_true "run preserves marker identity across dotenv loading" grep -q '^WORKSPACE_DB_SUFFIX=_stable-dotenv-identity$' "$log"

archive_bin="$TEST_TMP/archive-bin"
archive_lsof_log="$TEST_TMP/archive-lsof.log"
archive_rails_log="$TEST_TMP/archive-rails.log"
archive_hook_log="$TEST_TMP/archive-hook.log"
archive_identity_log="$TEST_TMP/archive-identity.log"
mkdir -p "$archive_bin"
cat > "$archive_bin/lsof" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$WORKSPACE_TEST_LSOF_LOG"
exit 1
SCRIPT
cat > bin/rails <<'SCRIPT'
#!/bin/sh
printf '%s:%s:%s\n' "$RAILS_ENV" "$WORKSPACE_DB_SUFFIX" "$*" >> "$WORKSPACE_TEST_ARCHIVE_LOG"
SCRIPT
cat > bin/workspace-archive-hook <<'SCRIPT'
#!/bin/sh
printf 'archive-hook\n' >> "$WORKSPACE_TEST_ARCHIVE_HOOK_LOG"
SCRIPT
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
printf 'identity-hook\n' >> "$WORKSPACE_TEST_ARCHIVE_IDENTITY_LOG"
printf 'stable-help-identity\n'
SCRIPT
chmod +x "$archive_bin/lsof" bin/rails bin/workspace-archive-hook bin/workspace-identity-hook
rm -f .conductor-workspace .workspace

archive_help_expected="$TEST_TMP/archive-help.expected"
cat > "$archive_help_expected" <<'EOF'
Usage: workspace archive

Stops processes using this workspace's reserved ports and drops its development
and test databases. Runs bin/workspace-archive-hook first when present.
The original checkout is left alone.
EOF

archive_help_first_output=""
for help_case in long short; do
  case "$help_case" in
    long) help_flag="--help" ;;
    short) help_flag="-h" ;;
  esac
  : > "$archive_identity_log"
  : > "$archive_hook_log"
  : > "$archive_lsof_log"
  : > "$archive_rails_log"
  help_output="$TEST_TMP/archive-help-$help_case.out"
  help_error="$TEST_TMP/archive-help-$help_case.err"

  PATH="$archive_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" \
    CONDUCTOR_WORKSPACE_NAME="help-provider-workspace" CONDUCTOR_PORT=51500 \
    WORKSPACE_TEST_LSOF_LOG="$archive_lsof_log" \
    WORKSPACE_TEST_ARCHIVE_LOG="$archive_rails_log" \
    WORKSPACE_TEST_ARCHIVE_HOOK_LOG="$archive_hook_log" \
    WORKSPACE_TEST_ARCHIVE_IDENTITY_LOG="$archive_identity_log" \
    "$WORKSPACE_HOME/bin/workspace" archive "$help_flag" >"$help_output" 2>"$help_error"
  help_status=$?

  assert_equal "archive $help_flag exits successfully" "0" "$help_status"
  assert_true "archive $help_flag prints exact help" cmp -s "$archive_help_expected" "$help_output"
  assert_true "archive $help_flag writes nothing to stderr" [ ! -s "$help_error" ]
  assert_false "archive $help_flag has no ANSI styling" grep -q "$(printf '\033')" "$help_output"
  assert_equal "archive $help_flag skips identity resolution" "" "$(cat "$archive_identity_log")"
  assert_equal "archive $help_flag skips archive hook" "" "$(cat "$archive_hook_log")"
  assert_equal "archive $help_flag skips port inspection" "" "$(cat "$archive_lsof_log")"
  assert_equal "archive $help_flag skips database cleanup" "" "$(cat "$archive_rails_log")"
  assert_false "archive $help_flag creates no Conductor marker" [ -e .conductor-workspace ]
  assert_false "archive $help_flag creates no workspace marker" [ -e .workspace ]

  if [ -z "$archive_help_first_output" ]; then
    archive_help_first_output="$help_output"
  else
    assert_true "archive help flags print identical output" cmp -s "$archive_help_first_output" "$help_output"
  fi
done

: > "$archive_hook_log"
: > "$archive_lsof_log"
: > "$archive_rails_log"
printf '%s' "stable-archive-name" > .conductor-workspace
printf '%s' "stale-workspace-name" > .workspace
PATH="$archive_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="renamed-provider-workspace" \
  WORKSPACE_TEST_LSOF_LOG="$archive_lsof_log" \
  WORKSPACE_TEST_ARCHIVE_LOG="$archive_rails_log" \
  WORKSPACE_TEST_ARCHIVE_HOOK_LOG="$archive_hook_log" \
  sh "$WORKSPACE_HOME/lib/archive.sh" >/dev/null 2>&1
assert_equal "archive honors dotenv workspace port block" "10" "$(wc -l < "$archive_lsof_log" | tr -d ' ')"
assert_true "archive starts dotenv port sweep at the explicit base" grep -q -- '-ti :51500' "$archive_lsof_log"
assert_true "archive ends dotenv port sweep at the block boundary" grep -q -- '-ti :51509' "$archive_lsof_log"
assert_true "archive database cleanup uses authoritative Conductor identity" grep -q '^development:_stable-archive-name:db:drop$' "$archive_rails_log"

# A malformed or failing dotenv must stop archive before partial environment
# values can reach hooks, port sweeps, or database cleanup. A Git registry entry
# remains available for a later safe recovery attempt.
failing_archive_output="$TEST_TMP/failing-archive.out"
: > "$archive_rails_log"
: > "$archive_lsof_log"
cat > .env <<'ENV'
WORKSPACE_NAME=wrong-partial-identity
WORKSPACE_PROVIDER=wrong-partial-provider
WORKSPACE_ROOT_PATH=/wrong/partial/root
WORKSPACE_PORT=65535
DATABASE_URL=postgres://wrong-partial.example.test/wrong
false
ENV
assert_false "archive fails when dotenv loading fails" env PATH="$archive_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="renamed-provider-workspace" CONDUCTOR_PORT=51600 WORKSPACE_TEST_LSOF_LOG="$archive_lsof_log" WORKSPACE_TEST_ARCHIVE_LOG="$archive_rails_log" sh "$WORKSPACE_HOME/lib/archive.sh" >"$failing_archive_output" 2>&1
assert_true "archive explains dotenv failure" grep -q 'Could not load .env.*archive stopped before cleanup' "$failing_archive_output"
assert_equal "failed dotenv reaches no database command" "" "$(cat "$archive_rails_log")"
assert_equal "failed dotenv reaches no port sweep" "" "$(cat "$archive_lsof_log")"

# Without an override, preserve the historical generic URL.
paths=$(make_run_app "url-fallback")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/url-fallback.log"
output="$TEST_TMP/url-fallback.out"
cd "$app_dir"
PATH="$fake_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="fallback-workspace" CONDUCTOR_PORT=51300 \
  WORKSPACE_TEST_RUN_LOG="$log" sh "$WORKSPACE_HOME/lib/run.sh" >"$output" 2>&1

assert_true "non-Caddy URL fallback is unchanged" grep -q 'http://localhost:51300' "$output"

# Caddy projects retain the historical HTTPS fallback when the hook does not
# provide a project-specific URL.
paths=$(make_run_app "caddy-fallback")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/caddy-fallback.log"
output="$TEST_TMP/caddy-fallback.out"
printf 'caddy: caddy run\n' > "$app_dir/Procfile.dev"
cd "$app_dir"
PATH="$fake_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" \
  CONDUCTOR_WORKSPACE_NAME="caddy-workspace" CONDUCTOR_PORT=51400 \
  WORKSPACE_TEST_RUN_LOG="$log" sh "$WORKSPACE_HOME/lib/run.sh" >"$output" 2>&1

assert_true "Caddy URL fallback is unchanged" grep -q 'https://caddy-fallback.localhost:51400' "$output"

# A provider identity that sanitizes to empty must stop before Foreman starts.
paths=$(make_run_app "invalid-name")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/invalid-name.log"
cd "$app_dir"
assert_false "unsafe workspace identity is rejected before run" env PATH="$fake_bin:$PATH" \
  SUPERSET_ROOT_PATH="$root_dir" SUPERSET_WORKSPACE_NAME="///" \
  WORKSPACE_TEST_RUN_LOG="$log" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_false "unsafe workspace identity does not start Foreman" [ -f "$log" ]

# Root/default runs must not inherit an isolated suffix, including from dotenv.
paths=$(make_run_app "root-suffix-protection")
app_dir=${paths%%|*}
root_dir=${paths#*|}
log="$TEST_TMP/root-suffix-protection.log"
printf 'WORKSPACE_DB_SUFFIX=_unsafe-default\n' > "$app_dir/.env"
cat > "$app_dir/bin/workspace-identity-hook" <<'SCRIPT'
#!/bin/sh
touch .identity-hook-called
printf '%s' "must-not-isolate-root"
SCRIPT
cat > "$app_dir/bin/workspace-archive-hook" <<'SCRIPT'
#!/bin/sh
touch .archive-hook-called
SCRIPT
chmod +x "$app_dir/bin/workspace-identity-hook" "$app_dir/bin/workspace-archive-hook"
cd "$app_dir"
PATH="$fake_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" \
  WORKSPACE_TEST_RUN_LOG="$log" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_true "root run clears dotenv workspace suffix" grep -q '^WORKSPACE_DB_SUFFIX=$' "$log"
assert_false "root run ignores identity hook" [ -f .identity-hook-called ]
assert_true "root archive exits without isolation" env CONDUCTOR_ROOT_PATH="$root_dir" sh "$WORKSPACE_HOME/lib/archive.sh" >/dev/null 2>&1
assert_false "root archive ignores identity hook" [ -f .identity-hook-called ]
assert_false "root archive does not run isolated archive hook" [ -f .archive-hook-called ]

report "run lifecycle"
