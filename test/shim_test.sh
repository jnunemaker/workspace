#!/bin/sh
# Tests for the project-local bin/workspace entrypoint.

cd "$(dirname "$0")"
. ./test_helper.sh

run_init() {
  sh "$WORKSPACE_HOME/lib/init.sh" >/dev/null 2>&1
}

app_dir=$(create_fake_app "shim")
cd "$app_dir"
run_init

# Provider shells often omit user dotfiles. The canonical install location must
# work even when Workspace is absent from PATH.
output="$TEST_TMP/shim-canonical.out"
assert_true "shim finds canonical install without PATH setup" env PATH="/usr/bin:/bin" HOME="$TEST_TMP/home" WORKSPACE_HOME="$WORKSPACE_HOME" bin/workspace info >"$output" 2>&1
assert_true "canonical shim executes workspace info" grep -q '^Provider: default$' "$output"

# The documented default install is also usable when WORKSPACE_HOME is absent.
mkdir -p "$TEST_TMP/default-home"
ln -s "$WORKSPACE_HOME" "$TEST_TMP/default-home/.workspace"
output="$TEST_TMP/shim-default-home.out"
assert_true "shim finds the default HOME install without dotfiles" env PATH="/usr/bin:/bin" HOME="$TEST_TMP/default-home" WORKSPACE_HOME= bin/workspace info >"$output" 2>&1
assert_true "default HOME install executes workspace info" grep -q '^Provider: default$' "$output"

mkdir -p "$TEST_TMP/symlink-prefix/bin" "$TEST_TMP/symlink-prefix/lib"
ln -s "$WORKSPACE_HOME/bin/workspace" "$TEST_TMP/symlink-prefix/bin/workspace"
output="$TEST_TMP/global-cli-symlink.out"
assert_true "global CLI symlink ignores an unrelated prefix lib directory" env PATH="/usr/bin:/bin" HOME="$TEST_TMP/default-home" WORKSPACE_HOME= "$TEST_TMP/symlink-prefix/bin/workspace" info >"$output" 2>&1
assert_true "global CLI symlink reaches workspace info" grep -q '^Provider: default$' "$output"

# If the repository's bin directory appears on PATH, the shim must recognize
# itself and fall back instead of recursing forever.
output="$TEST_TMP/shim-self-path.out"
assert_true "shim avoids recursion when it finds itself on PATH" env PATH="$app_dir/bin:/usr/bin:/bin" HOME="$TEST_TMP/home" WORKSPACE_HOME="$WORKSPACE_HOME" bin/workspace info >"$output" 2>&1
assert_true "self-recursion fallback reaches workspace info" grep -q '^Provider: default$' "$output"

# A missing install produces a one-time actionable install command.
output="$TEST_TMP/shim-missing.out"
if env PATH="/usr/bin:/bin" HOME="$TEST_TMP/empty-home" WORKSPACE_HOME="$TEST_TMP/missing-workspace" bin/workspace info >"$output" 2>&1; then
  missing_status=0
else
  missing_status=$?
fi
assert_equal "shim exits like a missing command when Workspace is missing" "127" "$missing_status"
expected_missing_output='Workspace is not installed.
Install it with:
  curl -fsSL https://raw.githubusercontent.com/jnunemaker/workspace/main/install.sh | bash
Then rerun this command.'
assert_equal "missing install message gives steps in order" "$expected_missing_output" "$(cat "$output")"
assert_false "missing install is not a shell command-not-found error" grep -qi 'command not found' "$output"

# The committed minimum revision is enforced without downloading anything.
printf '%040d\n' 0 > .workspace-version
output="$TEST_TMP/shim-outdated.out"
assert_false "shim rejects an outdated Workspace install" env PATH="/usr/bin:/bin" HOME="$TEST_TMP/home" WORKSPACE_HOME="$WORKSPACE_HOME" bin/workspace info >"$output" 2>&1
assert_true "outdated message explains the version contract" grep -q '^Workspace is older than this repository requires\.$' "$output"
assert_true "outdated message gives exact update command" grep -qF "  $WORKSPACE_HOME/bin/workspace update" "$output"
assert_false "outdated check does not execute an update" grep -q 'Updating workspace CLI' "$output"

# PATH remains the first choice when it names a different executable.
mkdir -p "$TEST_TMP/path-bin"
cat > "$TEST_TMP/path-bin/workspace" <<'EOF'
#!/bin/sh
printf 'path-workspace:%s\n' "$*"
EOF
chmod +x "$TEST_TMP/path-bin/workspace"
: > .workspace-version
output=$(PATH="$TEST_TMP/path-bin:/usr/bin:/bin" WORKSPACE_HOME="$TEST_TMP/missing-workspace" bin/workspace info)
assert_equal "shim prefers Workspace from PATH" "path-workspace:info" "$output"

# The update command is always reachable so an outdated installation can be
# repaired using the exact command printed by the shim.
printf '%040d\n' 0 > .workspace-version
output=$(PATH="$TEST_TMP/path-bin:/usr/bin:/bin" WORKSPACE_HOME="$TEST_TMP/missing-workspace" bin/workspace update)
assert_equal "shim bypasses minimum revision check for update" "path-workspace:update" "$output"

# A PATH entry may be a symlink or wrapper outside the Workspace Git checkout.
# With a revision contract, fall back to the canonical install when that PATH
# candidate cannot prove the required revision instead of rejecting it as old.
git -C "$WORKSPACE_HOME" rev-parse HEAD > .workspace-version
rm -f "$TEST_TMP/path-bin/workspace"
ln -s "$WORKSPACE_HOME/bin/workspace" "$TEST_TMP/path-bin/workspace"
output="$TEST_TMP/shim-path-symlink.out"
assert_true "shim falls back from an unverifiable PATH symlink to canonical install" env PATH="$TEST_TMP/path-bin:/usr/bin:/bin" WORKSPACE_HOME="$WORKSPACE_HOME" bin/workspace info >"$output" 2>&1
assert_true "canonical fallback through PATH symlink reaches workspace info" grep -q '^Provider: default$' "$output"

rm -f "$TEST_TMP/path-bin/workspace"
cat > "$TEST_TMP/path-bin/workspace" <<EOF
#!/bin/sh
exec "$WORKSPACE_HOME/bin/workspace" "\$@"
EOF
chmod +x "$TEST_TMP/path-bin/workspace"
output="$TEST_TMP/shim-path-wrapper.out"
assert_true "shim falls back from an unverifiable PATH wrapper to canonical install" env PATH="$TEST_TMP/path-bin:/usr/bin:/bin" WORKSPACE_HOME="$WORKSPACE_HOME" bin/workspace info >"$output" 2>&1
assert_true "canonical fallback through PATH wrapper reaches workspace info" grep -q '^Provider: default$' "$output"

report "project workspace shim"
