#!/bin/sh
# Minimal test helper for workspace CLI tests.
# Each test file sources this, then calls assert functions.

WORKSPACE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ERRORS=""

# Create a temporary directory for test fixtures
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# Source the libraries
. "$WORKSPACE_HOME/lib/common.sh"
. "$WORKSPACE_HOME/lib/detect.sh"

assert_equal() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: ${description}\n    expected: '${expected}'\n    actual:   '${actual}'"
  fi
}

assert_true() {
  local description="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: ${description}"
  fi
}

assert_false() {
  local description="$1"
  shift
  if "$@"; then
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: ${description} (expected false, got true)"
  else
    PASS=$((PASS + 1))
  fi
}

# Call at the end of each test file
report() {
  local test_name="$1"
  TOTAL=$((PASS + FAIL))
  if [ $FAIL -eq 0 ]; then
    printf "  ✓ %s (%d tests)\n" "$test_name" "$TOTAL"
  else
    printf "  ✗ %s (%d passed, %d failed)\n" "$test_name" "$PASS" "$FAIL"
    printf "$ERRORS\n"
  fi
  return $FAIL
}

# Poll until a command succeeds, for up to 10 seconds.
wait_until() {
  _wait_until_tries=0
  until "$@"; do
    [ "$_wait_until_tries" -lt 100 ] || return 1
    sleep 0.1
    _wait_until_tries=$((_wait_until_tries + 1))
  done
}

# Initialize a Git repository at $1 and commit everything in it.
commit_git_repo() {
  git -C "$1" init -q -b main
  git -C "$1" config user.email "workspace-tests@example.com"
  git -C "$1" config user.name "Workspace Tests"
  git -C "$1" add -A
  git -C "$1" commit -qm "initial"
}

# Helper to create a fake app directory for testing
create_fake_app() {
  local app_dir="$TEST_TMP/$1"
  mkdir -p "$app_dir/bin" "$app_dir/config/credentials"

  # Create a minimal Gemfile
  cat > "$app_dir/Gemfile" <<'GEMFILE'
source "https://rubygems.org"
gem "rails"
GEMFILE

  echo "$app_dir"
}

# Helper to create a fake root (for symlink testing)
create_fake_root() {
  local root_dir="$TEST_TMP/root-$1"
  mkdir -p "$root_dir/config/credentials"
  echo "$root_dir"
}
