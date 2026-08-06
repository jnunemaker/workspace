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
cd "$app_dir"
PATH="$fake_bin:$PATH" CONDUCTOR_ROOT_PATH="$root_dir" \
  WORKSPACE_TEST_RUN_LOG="$log" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_true "root run clears dotenv workspace suffix" grep -q '^WORKSPACE_DB_SUFFIX=$' "$log"

report "run lifecycle"
