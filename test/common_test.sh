#!/bin/sh
# Tests for lib/common.sh — workspace name resolution and sanitization.

cd "$(dirname "$0")"
. ./test_helper.sh

# Clear any env vars from the host environment
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true

# ── resolve_workspace ────────────────────────────────────────────

# Prefers SUPERCONDUCTOR vars over SUPERSET and CONDUCTOR vars
SUPERCONDUCTOR_ROOT_PATH="/superconductor/root"
SUPERCONDUCTOR_WORKSPACE_NAME="superconductor-ws"
SUPERSET_ROOT_PATH="/superset/root"
CONDUCTOR_ROOT_PATH="/conductor/root"
SUPERSET_WORKSPACE_NAME="superset-ws"
CONDUCTOR_WORKSPACE_NAME="conductor-ws"
resolve_workspace
assert_equal "prefers SUPERCONDUCTOR_ROOT_PATH" "/superconductor/root" "$WORKSPACE_ROOT_PATH"
assert_equal "prefers SUPERCONDUCTOR_WORKSPACE_NAME" "superconductor-ws" "$WORKSPACE_NAME"

# Prefers SUPERSET vars over CONDUCTOR vars
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME
SUPERSET_ROOT_PATH="/superset/root"
CONDUCTOR_ROOT_PATH="/conductor/root"
SUPERSET_WORKSPACE_NAME="superset-ws"
CONDUCTOR_WORKSPACE_NAME="conductor-ws"
resolve_workspace
assert_equal "prefers SUPERSET_ROOT_PATH" "/superset/root" "$WORKSPACE_ROOT_PATH"
assert_equal "prefers SUPERSET_WORKSPACE_NAME" "superset-ws" "$WORKSPACE_NAME"

# Falls back to CONDUCTOR vars when SUPERSET and SUPERCONDUCTOR not set
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME
CONDUCTOR_ROOT_PATH="/conductor/root"
CONDUCTOR_WORKSPACE_NAME="conductor-ws"
resolve_workspace
assert_equal "falls back to CONDUCTOR_ROOT_PATH" "/conductor/root" "$WORKSPACE_ROOT_PATH"
assert_equal "falls back to CONDUCTOR_WORKSPACE_NAME" "conductor-ws" "$WORKSPACE_NAME"

# "default" workspace is treated as no workspace
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH
CONDUCTOR_WORKSPACE_NAME="default"
resolve_workspace
assert_equal "default becomes empty" "" "$WORKSPACE_NAME"

# No vars set → empty
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME
resolve_workspace
assert_equal "no vars → empty name" "" "$WORKSPACE_NAME"
assert_equal "no vars → empty root" "" "$WORKSPACE_ROOT_PATH"

# ── is_default_workspace ─────────────────────────────────────────

WORKSPACE_NAME=""
assert_true "empty name is default" is_default_workspace

WORKSPACE_NAME="feature-branch"
assert_false "named workspace is not default" is_default_workspace

# ── sanitize_workspace_name ──────────────────────────────────────

unset SUPERCONDUCTOR_WORKSPACE_NAME 2>/dev/null || true

# Clean name passes through unchanged
SUPERSET_WORKSPACE_NAME="my-feature"
sanitize_workspace_name
assert_equal "clean name unchanged" "my-feature" "$WORKSPACE_NAME"

# Special characters replaced with hyphens
SUPERSET_WORKSPACE_NAME="feat/add-thing@v2"
sanitize_workspace_name
assert_equal "special chars to hyphens" "feat-add-thing-v2" "$WORKSPACE_NAME"

# Consecutive hyphens collapsed
SUPERSET_WORKSPACE_NAME="a---b"
sanitize_workspace_name
assert_equal "collapse hyphens" "a-b" "$WORKSPACE_NAME"

# Leading/trailing hyphens stripped
SUPERSET_WORKSPACE_NAME="-leading-"
sanitize_workspace_name
assert_equal "strip leading/trailing hyphens" "leading" "$WORKSPACE_NAME"

# Truncated to at most 40 chars
SUPERSET_WORKSPACE_NAME="this-is-a-very-long-workspace-name-that-exceeds-forty-characters-limit"
sanitize_workspace_name
length=$(printf '%s' "$WORKSPACE_NAME" | wc -c | tr -d ' ')
assert_true "truncate to <= 40 chars" [ "$length" -le 40 ]
assert_true "truncated name is non-empty" [ "$length" -gt 0 ]

# Trailing hyphen after truncation is stripped
SUPERSET_WORKSPACE_NAME="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x"
sanitize_workspace_name
length=$(printf '%s' "$WORKSPACE_NAME" | wc -c | tr -d ' ')
last_char=$(printf '%s' "$WORKSPACE_NAME" | tail -c 1)
assert_true "no trailing hyphen after truncate" [ "$last_char" != "-" ]

# "default" skips sanitization
SUPERSET_WORKSPACE_NAME="default"
WORKSPACE_NAME="default"
sanitize_workspace_name
assert_equal "default skips sanitization" "default" "$WORKSPACE_NAME"

# Only sanitizes SUPERSET/SUPERCONDUCTOR names, not CONDUCTOR names
unset SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_WORKSPACE_NAME
CONDUCTOR_WORKSPACE_NAME="feat/weird-name"
resolve_workspace
sanitize_workspace_name
assert_equal "conductor names not sanitized" "feat/weird-name" "$WORKSPACE_NAME"

# ── detect_app_name ──────────────────────────────────────────────

# This test depends on the current directory name
cd "$TEST_TMP"
mkdir -p test_app && cd test_app
detect_app_name
assert_equal "app name from dir" "test_app" "$APP_NAME"

cd "$TEST_TMP"
mkdir -p "hyphen-app" && cd "hyphen-app"
detect_app_name
assert_equal "hyphens to underscores" "hyphen_app" "$APP_NAME"

# Clean up
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME

report "common.sh"
