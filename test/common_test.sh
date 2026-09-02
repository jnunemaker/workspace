#!/bin/sh
# Tests for lib/common.sh — workspace name resolution and sanitization.

cd "$(dirname "$0")"
. ./test_helper.sh

# Clear any env vars from the host environment
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME 2>/dev/null || true
CODEX_HOME="$TEST_TMP/no-codex-home"
export CODEX_HOME

assert_false "empty Git path is not canonicalized to cwd" canonical_git_path ""

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
assert_equal "superconductor provider retained" "superconductor" "$WORKSPACE_PROVIDER"

# Prefers SUPERSET vars over CONDUCTOR vars
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME
SUPERSET_ROOT_PATH="/superset/root"
CONDUCTOR_ROOT_PATH="/conductor/root"
SUPERSET_WORKSPACE_NAME="superset-ws"
CONDUCTOR_WORKSPACE_NAME="conductor-ws"
resolve_workspace
assert_equal "prefers SUPERSET_ROOT_PATH" "/superset/root" "$WORKSPACE_ROOT_PATH"
assert_equal "prefers SUPERSET_WORKSPACE_NAME" "superset-ws" "$WORKSPACE_NAME"
assert_equal "superset provider retained" "superset" "$WORKSPACE_PROVIDER"

# Falls back to CONDUCTOR vars when SUPERSET and SUPERCONDUCTOR not set
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME
CONDUCTOR_ROOT_PATH="/conductor/root"
CONDUCTOR_WORKSPACE_NAME="conductor-ws"
resolve_workspace
assert_equal "falls back to CONDUCTOR_ROOT_PATH" "/conductor/root" "$WORKSPACE_ROOT_PATH"
assert_equal "falls back to CONDUCTOR_WORKSPACE_NAME" "conductor-ws" "$WORKSPACE_NAME"
assert_equal "conductor provider retained" "conductor" "$WORKSPACE_PROVIDER"

# "default" workspace is treated as no workspace
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH
CONDUCTOR_WORKSPACE_NAME="default"
resolve_workspace
assert_equal "default becomes empty" "" "$WORKSPACE_NAME"

# No vars set → empty
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME
cd "$TEST_TMP"
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

# Repositories whose Git directory lives outside the checkout still resolve
# their root from Git's worktree inventory.
separate_root="$TEST_TMP/separate-root"
separate_git="$TEST_TMP/separate-git"
separate_worktree="$CODEX_HOME/worktrees/separate-worktree"
git init -q --separate-git-dir="$separate_git" "$separate_root"
git -C "$separate_root" config core.worktree "$separate_root"
git -C "$separate_root" config user.email "workspace-tests@example.com"
git -C "$separate_root" config user.name "Workspace Tests"
printf 'root\n' > "$separate_root/README.md"
git -C "$separate_root" add README.md
git -C "$separate_root" commit -qm "initial"
git -C "$separate_root" worktree add -q --detach "$separate_worktree"
separate_root=$(cd "$separate_root" && pwd -P)
cd "$separate_worktree"
resolve_workspace
assert_equal "separate Git directory root detected" "$separate_root" "$WORKSPACE_ROOT_PATH"
assert_equal "separate Git directory worktree detected" "git" "$WORKSPACE_PROVIDER"

git -C "$git_worktree" switch -q -c codex-attached
resolve_workspace
assert_equal "branch-attached Codex worktree stays detected" "git" "$WORKSPACE_PROVIDER"

# Branch-backed worktrees outside Codex receive the same generic isolation.
manual_worktree="$TEST_TMP/manual-worktree"
git -C "$git_root" worktree add -q -b manual-test "$manual_worktree"
cd "$manual_worktree"
resolve_workspace
assert_equal "manual git worktree gets its Git identity" "manual-worktree" "$WORKSPACE_NAME"
assert_equal "manual git worktree uses generic provider" "git" "$WORKSPACE_PROVIDER"

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

# Superset retains its historical 45-character database identity.
SUPERSET_WORKSPACE_NAME="this-is-a-very-long-workspace-name-that-exceeds-forty-characters-limit"
sanitize_workspace_name
length=$(printf '%s' "$WORKSPACE_NAME" | wc -c | tr -d ' ')
assert_equal "Superset truncates to its historical 45 characters" "45" "$length"

SUPERSET_WORKSPACE_NAME="123456789012345678901234567890123456789012345"
sanitize_workspace_name
assert_equal "exact 45-character Superset identity is preserved" "$SUPERSET_WORKSPACE_NAME" "$WORKSPACE_NAME"

# Superconductor and generic Git worktrees keep Workspace's 40-character limit.
SUPERCONDUCTOR_WORKSPACE_NAME="1234567890123456789012345678901234567890123456"
sanitize_workspace_name
length=$(printf '%s' "$WORKSPACE_NAME" | wc -c | tr -d ' ')
assert_equal "Superconductor truncates to 40 characters" "40" "$length"
unset SUPERCONDUCTOR_WORKSPACE_NAME

# Trailing hyphen after truncation is stripped
SUPERCONDUCTOR_WORKSPACE_NAME="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x"
sanitize_workspace_name
length=$(printf '%s' "$WORKSPACE_NAME" | wc -c | tr -d ' ')
last_char=$(printf '%s' "$WORKSPACE_NAME" | tail -c 1)
assert_true "no trailing hyphen after truncate" [ "$last_char" != "-" ]
unset SUPERCONDUCTOR_WORKSPACE_NAME

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

# ── prefer_workspace_file ────────────────────────────────────────

unset SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_WORKSPACE_NAME CONDUCTOR_WORKSPACE_NAME 2>/dev/null || true

# No marker or hook leaves the derived identity untouched.
mkdir -p "$TEST_TMP/no-file" && cd "$TEST_TMP/no-file"
WORKSPACE_NAME="from-env"
resolve_workspace_identity
assert_equal "no file leaves name alone" "from-env" "$WORKSPACE_NAME"

# Provider/Git discovery owns the root/default decision. Stale sibling markers
# and an adoption hook cannot turn the main checkout into an isolated one.
mkdir -p "$TEST_TMP/root-identity/bin" && cd "$TEST_TMP/root-identity"
printf '%s' "legacy-sibling" > .conductor-workspace
printf '%s' "workspace-sibling" > .workspace
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
touch .identity-hook-called
printf '%s' "hook-sibling"
SCRIPT
chmod +x bin/workspace-identity-hook
WORKSPACE_NAME=""
WORKSPACE_INVALID_NAME=""
resolve_workspace_identity
assert_equal "root ignores stable workspace markers" "" "$WORKSPACE_NAME"
assert_equal "root identity remains derived" "derived" "$WORKSPACE_IDENTITY_SOURCE"
assert_false "root identity bypasses adoption hook" [ -f .identity-hook-called ]

# An empty Workspace marker is invalid rather than silently re-keying.
mkdir -p "$TEST_TMP/empty-workspace" && cd "$TEST_TMP/empty-workspace"
: > .workspace
WORKSPACE_NAME="from-env"
assert_false "empty .workspace is rejected" resolve_workspace_identity

# Non-regular markers cannot be read or atomically replaced. Resolution rejects
# them before bootstrap can run project setup or prepare databases.
mkdir -p "$TEST_TMP/directory-workspace" && cd "$TEST_TMP/directory-workspace"
mkdir .workspace
WORKSPACE_NAME="from-env"
assert_false "directory .workspace is rejected during resolution" resolve_workspace_identity
assert_false "directory .workspace is rejected during persistence" write_workspace_identity
assert_equal "directory .workspace remains empty" "" "$(find .workspace -mindepth 1 -maxdepth 1 -print)"

mkdir -p "$TEST_TMP/directory-conductor" && cd "$TEST_TMP/directory-conductor"
mkdir .conductor-workspace
printf '%s' "workspace-fallback" > .workspace
WORKSPACE_NAME="from-env"
assert_false "directory .conductor-workspace is rejected during resolution" resolve_workspace_identity

mkdir -p "$TEST_TMP/linked-conductor" && cd "$TEST_TMP/linked-conductor"
printf '%s' "linked-conductor-name" > conductor-identity-target
ln -s conductor-identity-target .conductor-workspace
printf '%s' "workspace-fallback" > .workspace
WORKSPACE_NAME="from-env"
assert_false "linked .conductor-workspace is rejected during resolution" resolve_workspace_identity

# A matching marker produces no warning.
mkdir -p "$TEST_TMP/match" && cd "$TEST_TMP/match"
printf '%s' "atlanta" > .workspace
WORKSPACE_NAME="atlanta"
resolve_workspace_identity >"$TEST_TMP/out" 2>&1
assert_equal "matching file keeps name" "atlanta" "$WORKSPACE_NAME"
assert_false "no warning when matching" [ -s "$TEST_TMP/out" ]

# Workspace's marker wins over a drifted provider identity.
mkdir -p "$TEST_TMP/drift" && cd "$TEST_TMP/drift"
printf '%s' "atlanta" > .workspace
WORKSPACE_NAME="some-drifted-name"
resolve_workspace_identity >"$TEST_TMP/out" 2>&1
assert_equal "file wins over drifted env" "atlanta" "$WORKSPACE_NAME"
assert_true "warns on drift" grep -q "drift" "$TEST_TMP/out"

# Existing Conductor identity is the highest authority during migration.
mkdir -p "$TEST_TMP/conductor-marker" && cd "$TEST_TMP/conductor-marker"
printf '%s' "workspace-value" > .workspace
printf '%s' "legacy-database" > .conductor-workspace
WORKSPACE_NAME="provider-value"
resolve_workspace_identity >"$TEST_TMP/out" 2>&1
assert_equal "Conductor marker wins over Workspace and provider" "legacy-database" "$WORKSPACE_NAME"
assert_equal "Conductor marker source recorded" ".conductor-workspace" "$WORKSPACE_IDENTITY_SOURCE"

# An empty legacy marker was historically unpinned and defers to Workspace.
mkdir -p "$TEST_TMP/empty-conductor" && cd "$TEST_TMP/empty-conductor"
: > .conductor-workspace
printf '%s' "workspace-value" > .workspace
WORKSPACE_NAME="provider-value"
resolve_workspace_identity >/dev/null 2>&1
assert_equal "empty legacy marker defers to Workspace" "workspace-value" "$WORKSPACE_NAME"

# A project hook can supply its established identity until Workspace pins it.
mkdir -p "$TEST_TMP/identity-hook/bin" && cd "$TEST_TMP/identity-hook"
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
printf '%s' "stable-git-id"
SCRIPT
chmod +x bin/workspace-identity-hook
WORKSPACE_NAME="provider-display-name"
WORKSPACE_PROVIDER="conductor"
WORKSPACE_ROOT_PATH="/provider/root"
resolve_workspace_identity >"$TEST_TMP/out" 2>&1
assert_equal "identity hook overrides provider display name" "stable-git-id" "$WORKSPACE_NAME"
assert_equal "identity hook source recorded" "bin/workspace-identity-hook" "$WORKSPACE_IDENTITY_SOURCE"

printf '%s' "pinned-name" > .workspace
WORKSPACE_NAME="new-provider-name"
resolve_workspace_identity >"$TEST_TMP/out" 2>&1
assert_equal "Workspace marker prevents hook from re-keying" "pinned-name" "$WORKSPACE_NAME"

# Invalid persisted or hook identities fail instead of choosing another DB.
mkdir -p "$TEST_TMP/multiline-identity" && cd "$TEST_TMP/multiline-identity"
printf 'first\nsecond\n' > .workspace
WORKSPACE_NAME="provider-value"
assert_false "multiline .workspace is rejected" resolve_workspace_identity

mkdir -p "$TEST_TMP/control-identity" && cd "$TEST_TMP/control-identity"
printf 'bad\tidentity' > .workspace
WORKSPACE_NAME="provider-value"
assert_false "control characters in .workspace are rejected" resolve_workspace_identity

mkdir -p "$TEST_TMP/control-identity-hook/bin" && cd "$TEST_TMP/control-identity-hook"
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
printf 'bad\033identity'
SCRIPT
chmod +x bin/workspace-identity-hook
WORKSPACE_NAME="provider-value"
WORKSPACE_PROVIDER="conductor"
WORKSPACE_ROOT_PATH="/provider/root"
assert_false "control characters in identity hook output are rejected" resolve_workspace_identity

mkdir -p "$TEST_TMP/failing-identity-hook/bin" && cd "$TEST_TMP/failing-identity-hook"
cat > bin/workspace-identity-hook <<'SCRIPT'
#!/bin/sh
exit 42
SCRIPT
chmod +x bin/workspace-identity-hook
WORKSPACE_NAME="provider-value"
assert_false "failing identity hook aborts resolution" resolve_workspace_identity

cd "$TEST_DIR"

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
