#!/bin/sh
# Tests for lib/common.sh — workspace name resolution and sanitization.

cd "$(dirname "$0")"
. ./test_helper.sh

# Clear any env vars from the host environment
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME CODEX_HOME 2>/dev/null || true

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

# Linked Git worktrees are detected when provider variables are absent.
git_root="$TEST_TMP/git-root"
CODEX_HOME="$TEST_TMP/codex"
git_worktree="$CODEX_HOME/worktrees/git-worktree"
mkdir -p "$git_root" "$CODEX_HOME/worktrees"
git -C "$git_root" init -q
git -C "$git_root" config user.email "workspace-tests@example.com"
git -C "$git_root" config user.name "Workspace Tests"
printf 'root\n' > "$git_root/README.md"
git -C "$git_root" add README.md
git -C "$git_root" commit -qm "initial"
git -C "$git_root" worktree add -q --detach "$git_worktree"
git_root=$(cd "$git_root" && pwd -P)
git_worktree=$(cd "$git_worktree" && pwd -P)

cd "$git_worktree"
resolve_workspace
assert_equal "git worktree root detected" "$git_root" "$WORKSPACE_ROOT_PATH"
assert_true "git worktree gets a name" [ -n "$WORKSPACE_NAME" ]
assert_equal "git worktree provider detected" "git" "$WORKSPACE_PROVIDER"
assert_equal "git common dir recorded" "$git_root/.git" "$WORKSPACE_GIT_COMMON_DIR"

git -C "$git_worktree" switch -q -c codex-attached
resolve_workspace
assert_equal "branch-attached Codex worktree stays detected" "git" "$WORKSPACE_PROVIDER"

# Branch-backed worktrees outside Codex retain their historical default state.
manual_worktree="$TEST_TMP/manual-worktree"
git -C "$git_root" worktree add -q -b manual-test "$manual_worktree"
cd "$manual_worktree"
resolve_workspace
assert_equal "manual git worktree stays default" "" "$WORKSPACE_NAME"
assert_equal "manual git worktree has no provider" "" "$WORKSPACE_PROVIDER"

# Existing provider variables retain priority even inside a Git worktree.
cd "$git_worktree"
SUPERSET_ROOT_PATH="/superset/root"
SUPERSET_WORKSPACE_NAME="superset-ws"
resolve_workspace
assert_equal "superset root still wins in git worktree" "/superset/root" "$WORKSPACE_ROOT_PATH"
assert_equal "superset name still wins in git worktree" "superset-ws" "$WORKSPACE_NAME"
assert_equal "superset provider retained" "superset" "$WORKSPACE_PROVIDER"

unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME
cd "$git_root"
resolve_workspace
assert_equal "main git checkout stays default" "" "$WORKSPACE_NAME"
assert_equal "main git checkout has no provider" "" "$WORKSPACE_PROVIDER"

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
