#!/bin/sh
# Tests for workspace update output.

cd "$(dirname "$0")"
. ./test_helper.sh

fake_workspace="$TEST_TMP/workspace"
fake_bin="$TEST_TMP/bin"
git_state="$TEST_TMP/git-version"
install_marker="$TEST_TMP/install-runs"
pull_marker="$TEST_TMP/pull-runs"
curl_marker="$TEST_TMP/curl-runs"
mkdir -p "$fake_workspace/.git" "$fake_workspace/lib" "$fake_bin"

cat > "$fake_bin/git" <<'SCRIPT'
#!/bin/sh
shift 2

case "$1" in
  log)
    cat "$FAKE_GIT_STATE"
    ;;
  pull)
    printf 'pulled\n' >> "$FAKE_GIT_PULL_MARKER"
    if [ -n "${FAKE_GIT_UPDATE_VERSION:-}" ]; then
      printf '%s\n' "$FAKE_GIT_UPDATE_VERSION" > "$FAKE_GIT_STATE"
    fi
    ;;
  *)
    exit 1
    ;;
esac
SCRIPT

cat > "$fake_bin/curl" <<'SCRIPT'
#!/bin/sh
printf 'curled\n' >> "$FAKE_CURL_MARKER"
case "${FAKE_CURL_MODE:-}" in
  fail) exit 22 ;;
  partial) printf 'echo partial-installer-ran\n'; exit 18 ;;
  *) printf 'echo installer-ran\nexit 7\n' ;;
esac
SCRIPT

cat > "$fake_workspace/lib/install_skill.sh" <<'SCRIPT'
#!/bin/sh
printf 'installed\n' >> "$UPDATE_INSTALL_MARKER"
SCRIPT
chmod +x "$fake_bin/git" "$fake_bin/curl" "$fake_workspace/lib/install_skill.sh"

old_version="1111111 (2026-08-12)"
new_version="2222222 (2026-08-13)"

update_help_expected="$TEST_TMP/update-help.expected"
cat > "$update_help_expected" <<'EOF'
Usage: workspace update

Updates the shared Workspace CLI and refreshes any installed Claude Code or
Codex Workspace skill. It does not change files in application repositories.
Run workspace init separately to refresh generated project files.
EOF

update_help_first_output=""
for help_case in long short; do
  case "$help_case" in
    long) help_flag="--help" ;;
    short) help_flag="-h" ;;
  esac
  printf '%s\n' "$old_version" > "$git_state"
  rm -f "$install_marker" "$pull_marker" "$curl_marker"
  help_output="$TEST_TMP/update-help-$help_case.out"
  help_error="$TEST_TMP/update-help-$help_case.err"
  env PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$fake_workspace" \
    FAKE_GIT_STATE="$git_state" FAKE_GIT_UPDATE_VERSION="$new_version" \
    FAKE_GIT_PULL_MARKER="$pull_marker" FAKE_CURL_MARKER="$curl_marker" \
    UPDATE_INSTALL_MARKER="$install_marker" \
    "$WORKSPACE_HOME/bin/workspace" update "$help_flag" >"$help_output" 2>"$help_error"
  help_status=$?

  assert_equal "update $help_flag exits successfully" "0" "$help_status"
  assert_true "update $help_flag prints exact help" cmp -s "$update_help_expected" "$help_output"
  assert_true "update $help_flag writes nothing to stderr" [ ! -s "$help_error" ]
  assert_false "update $help_flag has no ANSI styling" grep -q "$(printf '\033')" "$help_output"
  assert_equal "update $help_flag preserves installed version" "$old_version" "$(cat "$git_state")"
  assert_false "update $help_flag skips git pull" [ -e "$pull_marker" ]
  assert_false "update $help_flag skips skill installation" [ -e "$install_marker" ]
  assert_false "update $help_flag prints no update progress" grep -Eq 'Checking for workspace CLI updates|already up to date|workspace updated' "$help_output"

  if [ -z "$update_help_first_output" ]; then
    update_help_first_output="$help_output"
  else
    assert_true "update help flags print identical output" cmp -s "$update_help_first_output" "$help_output"
  fi
done

standalone_workspace="$TEST_TMP/standalone-workspace"
mkdir -p "$standalone_workspace"
for help_case in long short; do
  case "$help_case" in
    long) help_flag="--help" ;;
    short) help_flag="-h" ;;
  esac
  rm -f "$curl_marker"
  help_output="$TEST_TMP/update-standalone-help-$help_case.out"
  help_error="$TEST_TMP/update-standalone-help-$help_case.err"
  env PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$standalone_workspace" \
    FAKE_GIT_STATE="$git_state" FAKE_GIT_PULL_MARKER="$pull_marker" \
    FAKE_CURL_MARKER="$curl_marker" UPDATE_INSTALL_MARKER="$install_marker" \
    "$WORKSPACE_HOME/bin/workspace" update "$help_flag" >"$help_output" 2>"$help_error"
  help_status=$?

  assert_equal "standalone update $help_flag exits successfully" "0" "$help_status"
  assert_true "standalone update $help_flag prints exact help" cmp -s "$update_help_expected" "$help_output"
  assert_true "standalone update $help_flag writes nothing to stderr" [ ! -s "$help_error" ]
  assert_false "standalone update $help_flag skips curl" [ -e "$curl_marker" ]
done

version_help_expected="$TEST_TMP/version-help.expected"
cat > "$version_help_expected" <<'EOF'
Usage: workspace version

Prints the installed Workspace version.
EOF
printf '%s\n' "$old_version" > "$git_state"
version_help_first_output=""
for help_case in long short; do
  case "$help_case" in
    long) help_flag="--help" ;;
    short) help_flag="-h" ;;
  esac
  help_output="$TEST_TMP/version-help-$help_case.out"
  help_error="$TEST_TMP/version-help-$help_case.err"
  env PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$fake_workspace" \
    FAKE_GIT_STATE="$git_state" "$WORKSPACE_HOME/bin/workspace" version "$help_flag" >"$help_output" 2>"$help_error"
  help_status=$?

  assert_equal "version $help_flag exits successfully" "0" "$help_status"
  assert_true "version $help_flag prints exact help" cmp -s "$version_help_expected" "$help_output"
  assert_true "version $help_flag writes nothing to stderr" [ ! -s "$help_error" ]
  assert_false "version $help_flag has no ANSI styling" grep -q "$(printf '\033')" "$help_output"

  if [ -z "$version_help_first_output" ]; then
    version_help_first_output="$help_output"
  else
    assert_true "version help flags print identical output" cmp -s "$version_help_first_output" "$help_output"
  fi
done

for version_case in plain long short trailing; do
  case "$version_case" in
    plain) set -- version ;;
    long) set -- --version ;;
    short) set -- -v ;;
    trailing) set -- version ignored --help ;;
  esac
  output=$(env PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$fake_workspace" \
    FAKE_GIT_STATE="$git_state" "$WORKSPACE_HOME/bin/workspace" "$@")
  assert_equal "version $version_case invocation is unchanged" "workspace $old_version" "$output"
done

rm -f "$install_marker" "$pull_marker" "$curl_marker"
printf '%s\n' "$old_version" > "$git_state"
output=$(PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$fake_workspace" FAKE_GIT_STATE="$git_state" FAKE_GIT_PULL_MARKER="$pull_marker" UPDATE_INSTALL_MARKER="$install_marker" "$WORKSPACE_HOME/bin/workspace" update)
expected="Checking for workspace CLI updates...
workspace already up to date at $old_version"
assert_equal "unchanged update reports already up to date" "$expected" "$output"

output=$(PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$fake_workspace" FAKE_GIT_STATE="$git_state" FAKE_GIT_UPDATE_VERSION="$new_version" FAKE_GIT_PULL_MARKER="$pull_marker" UPDATE_INSTALL_MARKER="$install_marker" "$WORKSPACE_HOME/bin/workspace" update)
expected="Checking for workspace CLI updates...
workspace updated to $new_version"
assert_equal "changed update reports the new version" "$expected" "$output"

assert_equal "skill installation still runs after every update" "2" "$(wc -l < "$install_marker" | tr -d ' ')"

# Standalone installs (no .git) re-run the installer. A failed or partial
# download must fail loudly instead of piping nothing into bash.
for curl_mode in fail partial; do
  rm -f "$curl_marker"
  curl_output="$TEST_TMP/update-curl-$curl_mode.out"
  curl_error="$TEST_TMP/update-curl-$curl_mode.err"
  env PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$standalone_workspace" \
    FAKE_CURL_MARKER="$curl_marker" FAKE_CURL_MODE="$curl_mode" \
    "$WORKSPACE_HOME/bin/workspace" update >"$curl_output" 2>"$curl_error"
  curl_status=$?

  assert_true "standalone update downloads the installer ($curl_mode)" [ -e "$curl_marker" ]
  assert_false "standalone update fails when the download fails ($curl_mode)" [ "$curl_status" -eq 0 ]
  assert_true "standalone update explains a failed download ($curl_mode)" grep -q "could not download the installer" "$curl_error"
  assert_false "standalone update runs nothing from a failed download ($curl_mode)" grep -q "partial-installer-ran" "$curl_output"
done

output=$(env PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$standalone_workspace" \
  FAKE_CURL_MARKER="$curl_marker" \
  "$WORKSPACE_HOME/bin/workspace" update 2>&1)
curl_status=$?
expected="Checking for workspace CLI updates...
installer-ran"
assert_equal "standalone update runs a downloaded installer" "$expected" "$output"
assert_equal "standalone update exits with the installer's status" "7" "$curl_status"

# A linked Git worktree or submodule has a .git file, not a directory. Update it
# with git rather than reinstalling, which would delete the checkout.
worktree_workspace="$TEST_TMP/worktree-workspace"
mkdir -p "$worktree_workspace/lib"
printf 'gitdir: /somewhere/.git/worktrees/dev\n' > "$worktree_workspace/.git"
printf 'uncommitted\n' > "$worktree_workspace/notes.txt"
cp "$fake_workspace/lib/install_skill.sh" "$worktree_workspace/lib/install_skill.sh"
rm -f "$pull_marker" "$curl_marker"
env PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$worktree_workspace" \
  FAKE_GIT_STATE="$git_state" FAKE_GIT_PULL_MARKER="$pull_marker" \
  FAKE_CURL_MARKER="$curl_marker" UPDATE_INSTALL_MARKER="$install_marker" \
  "$WORKSPACE_HOME/bin/workspace" update >/dev/null 2>&1
assert_true "worktree update pulls with git" [ -e "$pull_marker" ]
assert_false "worktree update does not download the installer" [ -e "$curl_marker" ]
assert_true "worktree update keeps the checkout's files" [ -f "$worktree_workspace/notes.txt" ]

report "workspace update"
