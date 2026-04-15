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
