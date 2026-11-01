#!/bin/sh
# Shared URL configuration must not execute project startup during inspection.
cd "$(dirname "$0")" || exit 1
. ./test_helper.sh
[ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ] || exit 1
unset WORKSPACE_APP_URL WORKSPACE_APP_URL_TEMPLATE WORKSPACE_PORT
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_PORT
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME SUPERSET_PORT
unset CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME CONDUCTOR_PORT
app="$TEST_TMP/app"
mkdir -p "$app/bin" "$TEST_TMP/tools" || exit 1
cat > "$TEST_TMP/tools/lsof" <<'SCRIPT'
#!/bin/sh
exit 1
SCRIPT
cat > "$app/bin/foreman" <<'SCRIPT'
#!/bin/sh
printf '%s' "$PORT" > "$URL_TEST_LOG"
SCRIPT
cat > "$app/bin/workspace-run-hook" <<'SCRIPT'
#!/bin/sh
printf run >> "$URL_TEST_HOOK_LOG"
[ -z "${URL_TEST_OVERRIDE:-}" ] || WORKSPACE_APP_URL="$URL_TEST_OVERRIDE"
SCRIPT
cat > "$app/bin/workspace-environment-hook" <<'SCRIPT'
printf environment >> "$URL_TEST_HOOK_LOG"
SCRIPT
chmod +x "$TEST_TMP/tools/lsof" "$app/bin/foreman" "$app/bin/workspace-run-hook"
export PATH="$TEST_TMP/tools:$PATH" URL_TEST_LOG="$TEST_TMP/foreman" URL_TEST_HOOK_LOG="$TEST_TMP/hooks"
cd "$app" || exit 1
printf 'caddy: caddy run\n' > Procfile.dev
cat > .env <<'ENV'
WORKSPACE_APP_URL_TEMPLATE='https://app.example.localhost:{port}/login'
WORKSPACE_PORT=57690
ENV
info=$(sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "info fills project URL with resolved dotenv port" sh -c 'printf "%s\n" "$1" | grep -qx "URL: https://app.example.localhost:57690/login"' sh "$info"
assert_false "info does not run project hooks" test -e "$URL_TEST_HOOK_LOG"
assert_false "info does not start Foreman" test -e "$URL_TEST_LOG"
output=$(sh "$WORKSPACE_HOME/lib/run.sh")
assert_true "run displays same project URL" sh -c 'printf "%s\n" "$1" | grep -q "https://app.example.localhost:57690/login"' sh "$output"
assert_equal "display change preserves service port" 57690 "$(cat "$URL_TEST_LOG")"
output=$(WORKSPACE_PORT=57700 sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "explicit port replaces dotenv port in URL" sh -c 'printf "%s\n" "$1" | grep -q "URL: https://app.example.localhost:57700/login"' sh "$output"
output=$(WORKSPACE_APP_URL=https://explicit.test sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "complete explicit URL wins" sh -c 'printf "%s\n" "$1" | grep -qx "URL: https://explicit.test"' sh "$output"
printf 'WORKSPACE_APP_URL=https://dotenv.test\n' >> .env
output=$(sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "complete dotenv URL wins over template" sh -c 'printf "%s\n" "$1" | grep -qx "URL: https://dotenv.test"' sh "$output"
output=$(URL_TEST_OVERRIDE=https://hook.test sh "$WORKSPACE_HOME/lib/run.sh")
assert_true "legacy startup hook URL still wins" sh -c 'printf "%s\n" "$1" | grep -q "https://hook.test"' sh "$output"
rm .env
printf 'web: bin/rails server\n' > Procfile.dev
output=$(WORKSPACE_PORT=58000 WORKSPACE_APP_URL_TEMPLATE='http://custom.test:{port}' sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "non-Caddy template uses application port" sh -c 'printf "%s\n" "$1" | grep -qx "URL: http://custom.test:58000"' sh "$output"
output=$(WORKSPACE_PORT=58000 WORKSPACE_APP_URL_TEMPLATE='https://example.test:{port}/$(touch sentinel)?other={port}&literal={other}' sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "template replacement is literal" sh -c 'printf "%s\n" "$1" | grep -Fqx '\''URL: https://example.test:58000/$(touch sentinel)?other=58000&literal={other}'\''' sh "$output"
assert_false "template does not execute shell text" test -e sentinel
output=$(sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "unset template preserves fallback" sh -c 'printf "%s\n" "$1" | grep -qx "URL: http://localhost:3000"' sh "$output"
# The shared URL also follows a persisted Git reservation without creating
# one during info. All startup/process boundaries remain the same test doubles.
git init -q "$TEST_TMP/root" || exit 1
git -C "$TEST_TMP/root" -c user.name=Test -c user.email=test@example.com commit --no-gpg-sign -qm initial --allow-empty || exit 1
git -C "$TEST_TMP/root" worktree add -q --detach "$TEST_TMP/linked" || exit 1
cp -R "$app/bin" "$TEST_TMP/linked/bin" || exit 1
cd "$TEST_TMP/linked" || exit 1
touch Procfile.dev
printf "WORKSPACE_APP_URL_TEMPLATE='http://custom.test:{port}'\n" > .env
sh "$WORKSPACE_HOME/lib/info.sh" > "$TEST_TMP/info-before"
assert_false "info creates no cleanup registration" test -d "$TEST_TMP/root/.git/workspace/registry"
WORKSPACE_PORT=58100 sh "$WORKSPACE_HOME/lib/run.sh" > "$TEST_TMP/run-registered"
output=$(sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "info template follows registered port" sh -c 'printf "%s\n" "$1" | grep -qx "URL: http://custom.test:58100"' sh "$output"
assert_true "run template uses same registered port" grep -q 'http://custom.test:58100' "$TEST_TMP/run-registered"
report "project URL"
