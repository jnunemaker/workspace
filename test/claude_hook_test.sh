#!/bin/sh
# Tests for lib/claude_hook.sh — Claude Code session lifecycle hooks.

cd "$(dirname "$0")"
. ./test_helper.sh

hook_root="$TEST_TMP/claude-root"
hook_worktree="$TEST_TMP/claude-worktree"
codex_worktree="$TEST_TMP/claude-codex-worktree"
hook_log="$TEST_TMP/claude-hook.log"
fake_bin="$TEST_TMP/claude-fake-bin"
mkdir -p "$hook_root/bin" "$fake_bin"

# Port sweeps must never touch real processes.
cat > "$fake_bin/lsof" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$fake_bin/lsof"

cat > "$hook_root/bin/workspace" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$hook_root/bin/setup" <<'EOF'
#!/bin/sh
printf 'setup\n' >> "$WORKSPACE_TEST_LOG"
EOF
cat > "$hook_root/bin/workspace-archive-hook" <<'EOF'
#!/bin/sh
printf 'archive\n' >> "$WORKSPACE_TEST_LOG"
EOF
chmod +x "$hook_root/bin/workspace" "$hook_root/bin/setup" "$hook_root/bin/workspace-archive-hook"
printf '.workspace\n' > "$hook_root/.gitignore"
git -C "$hook_root" init -q -b main
git -C "$hook_root" config user.email "workspace-tests@example.com"
git -C "$hook_root" config user.name "Workspace Tests"
git -C "$hook_root" add .gitignore bin
git -C "$hook_root" commit -qm "initial"
git -C "$hook_root" worktree add -q -b claude/feature "$hook_worktree"
git -C "$hook_root" worktree add -q --detach "$codex_worktree"
hook_root=$(cd "$hook_root" && pwd -P)
hook_worktree=$(cd "$hook_worktree" && pwd -P)
codex_worktree=$(cd "$codex_worktree" && pwd -P)
worktree_git_dir=$(git -C "$hook_worktree" rev-parse --absolute-git-dir)

# Hooks run from the original checkout; the session worktree arrives as JSON.
run_hook() {
  printf '{"session_id":"abc","cwd":"%s","hook_event_name":"%s"}' "$2" "$1" \
    | (cd "$hook_root" && PATH="$fake_bin:$PATH" WORKSPACE_TEST_LOG="$hook_log" \
      sh "$WORKSPACE_HOME/lib/claude_hook.sh" "$1")
}

count_log() {
  { cat "$hook_log" 2>/dev/null || true; } | grep -c "^$1\$" || true
}

wait_for_file() {
  _wait=0
  while [ ! -e "$1" ] && [ "$_wait" -lt 50 ]; do
    sleep 0.2
    _wait=$((_wait + 1))
  done
}

assert_true "claude-hook without event shows usage and fails" sh -c '! sh "$1/lib/claude_hook.sh" </dev/null >/dev/null 2>&1' sh "$WORKSPACE_HOME"
assert_true "claude-hook --help succeeds" sh -c 'sh "$1/lib/claude_hook.sh" --help >/dev/null' sh "$WORKSPACE_HOME"

# ── session-start ────────────────────────────────────────────────

run_hook session-start "$hook_root" >/dev/null 2>&1
assert_equal "session-start ignores the original checkout" "0" "$(count_log setup)"

hook_stdout=$(run_hook session-start "$hook_worktree" 2>/dev/null)
assert_equal "session-start keeps bootstrap output out of Claude context" "" "$hook_stdout"
assert_equal "session-start bootstraps a new worktree" "1" "$(count_log setup)"
assert_true "session-start writes the identity marker" [ -s "$hook_worktree/.workspace" ]
assert_equal "session-start remembers the session branch" "claude/feature" "$(cat "$worktree_git_dir/workspace-claude-branch")"

run_hook session-start "$hook_worktree" >/dev/null 2>&1
assert_equal "session-start does not repeat bootstrap" "1" "$(count_log setup)"

printf '{"cwd":"%s"}' "$TEST_TMP/missing" | sh "$WORKSPACE_HOME/lib/claude_hook.sh" session-start >/dev/null 2>&1
assert_equal "session-start ignores a missing cwd" "0" "$?"

# ── session-end ──────────────────────────────────────────────────

run_hook session-end "$hook_worktree" >/dev/null 2>&1
sleep 1
assert_equal "session-end leaves an attached branch alone (app quit)" "0" "$(count_log archive)"

git -C "$hook_worktree" checkout -q --detach
mkdir "$worktree_git_dir/rebase-merge"
run_hook session-end "$hook_worktree" >/dev/null 2>&1
sleep 1
assert_equal "session-end ignores a rebase in progress" "0" "$(count_log archive)"
rmdir "$worktree_git_dir/rebase-merge"

run_hook session-end "$hook_worktree" >/dev/null 2>&1
wait_for_file "$worktree_git_dir/workspace-claude-archived"
assert_equal "session-end archives after the branch is released" "1" "$(count_log archive)"
assert_true "session-end records the archive" [ -f "$worktree_git_dir/workspace-claude-archived" ]
assert_false "session-end forgets the session branch" [ -f "$worktree_git_dir/workspace-claude-branch" ]
assert_true "session-end logs archive output" grep -q 'Archive complete' "$worktree_git_dir/workspace-claude.log"

run_hook session-end "$hook_worktree" >/dev/null 2>&1
sleep 1
assert_equal "session-end archives only once" "1" "$(count_log archive)"

# Unarchive reattaches the branch and resumes; databases must come back even
# though the .workspace marker survived archive.
git -C "$hook_worktree" checkout -q claude/feature
run_hook session-start "$hook_worktree" >/dev/null 2>&1
assert_equal "session-start rebootstraps an unarchived worktree" "2" "$(count_log setup)"
assert_false "session-start clears the archive record" [ -f "$worktree_git_dir/workspace-claude-archived" ]
run_hook session-start "$hook_worktree" >/dev/null 2>&1
assert_equal "session-start returns to bootstrap-once after recovery" "2" "$(count_log setup)"

# Worktrees that start detached (Codex) are never archived by Claude hooks.
run_hook session-start "$codex_worktree" >/dev/null 2>&1
run_hook session-end "$codex_worktree" >/dev/null 2>&1
sleep 1
codex_git_dir=$(git -C "$codex_worktree" rev-parse --absolute-git-dir)
assert_false "detached-at-start worktree has no session branch" [ -f "$codex_git_dir/workspace-claude-branch" ]
assert_equal "detached-at-start worktree is not archived" "1" "$(count_log archive)"

report "claude-hook"
