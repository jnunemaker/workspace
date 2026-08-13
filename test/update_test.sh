#!/bin/sh
# Tests for workspace update output.

cd "$(dirname "$0")"
. ./test_helper.sh

fake_workspace="$TEST_TMP/workspace"
fake_bin="$TEST_TMP/bin"
git_state="$TEST_TMP/git-version"
install_marker="$TEST_TMP/install-runs"
mkdir -p "$fake_workspace/.git" "$fake_workspace/lib" "$fake_bin"

cat > "$fake_bin/git" <<'SCRIPT'
#!/bin/sh
shift 2

case "$1" in
  log)
    cat "$FAKE_GIT_STATE"
    ;;
  pull)
    if [ -n "${FAKE_GIT_UPDATE_VERSION:-}" ]; then
      printf '%s\n' "$FAKE_GIT_UPDATE_VERSION" > "$FAKE_GIT_STATE"
    fi
    ;;
  *)
    exit 1
    ;;
esac
SCRIPT

cat > "$fake_workspace/lib/install_skill.sh" <<'SCRIPT'
#!/bin/sh
printf 'installed\n' >> "$UPDATE_INSTALL_MARKER"
SCRIPT
chmod +x "$fake_bin/git" "$fake_workspace/lib/install_skill.sh"

old_version="1111111 (2026-08-12)"
new_version="2222222 (2026-08-13)"

printf '%s\n' "$old_version" > "$git_state"
output=$(PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$fake_workspace" FAKE_GIT_STATE="$git_state" UPDATE_INSTALL_MARKER="$install_marker" "$WORKSPACE_HOME/bin/workspace" update)
expected="Updating workspace CLI...
workspace already up to date at $old_version"
assert_equal "unchanged update reports already up to date" "$expected" "$output"

output=$(PATH="$fake_bin:/usr/bin:/bin" WORKSPACE_HOME="$fake_workspace" FAKE_GIT_STATE="$git_state" FAKE_GIT_UPDATE_VERSION="$new_version" UPDATE_INSTALL_MARKER="$install_marker" "$WORKSPACE_HOME/bin/workspace" update)
expected="Updating workspace CLI...
workspace updated to $new_version"
assert_equal "changed update reports the new version" "$expected" "$output"

assert_equal "skill installation still runs after every update" "2" "$(wc -l < "$install_marker" | tr -d ' ')"

report "workspace update"
