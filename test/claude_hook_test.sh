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
[ -z "${WORKSPACE_TEST_SETUP_SLEEP:-}" ] || sleep "$WORKSPACE_TEST_SETUP_SLEEP"
printf 'setup\n' >> "$WORKSPACE_TEST_LOG"
EOF
cat > "$hook_root/bin/workspace-archive-hook" <<'EOF'
#!/bin/sh
[ -z "${WORKSPACE_TEST_ARCHIVE_SLEEP:-}" ] || sleep "$WORKSPACE_TEST_ARCHIVE_SLEEP"
printf 'archive\n' >> "$WORKSPACE_TEST_LOG"
[ -z "${WORKSPACE_TEST_ARCHIVE_FAIL:-}" ] || exit 1
EOF
chmod +x "$hook_root/bin/workspace" "$hook_root/bin/setup" "$hook_root/bin/workspace-archive-hook"
printf '.workspace\n' > "$hook_root/.gitignore"
git -C "$hook_root" init -q -b main
git -C "$hook_root" config user.email "workspace-tests@example.com"
git -C "$hook_root" config user.name "Workspace Tests"
mkdir -p "$hook_root/app"
printf 'app\n' > "$hook_root/app/README"
git -C "$hook_root" add .gitignore bin app
git -C "$hook_root" commit -qm "initial"
git -C "$hook_root" worktree add -q -b claude/feature "$hook_worktree"
git -C "$hook_root" worktree add -q --detach "$codex_worktree"
hook_root=$(cd "$hook_root" && pwd -P)
hook_worktree=$(cd "$hook_worktree" && pwd -P)
codex_worktree=$(cd "$codex_worktree" && pwd -P)
worktree_git_dir=$(git -C "$hook_worktree" rev-parse --absolute-git-dir)

# Hooks run from the original checkout; the session worktree arrives as JSON.
run_hook() {
  printf '{"session_id":"abc","cwd":"%s","hook_event_name":"%s","source":"%s"}' "$2" "$1" "${3:-startup}" \
    | (cd "$hook_root" && PATH="$fake_bin:$PATH" WORKSPACE_TEST_LOG="$hook_log" \
      sh "$WORKSPACE_HOME/lib/claude_hook.sh" "$1")
}

count_log() {
  { cat "$hook_log" 2>/dev/null || true; } | grep -c "^$1\$" || true
}

wait_for_archive() {
  _wait=0
  while [ -e "$worktree_git_dir/workspace-claude-archiving" ] && [ "$_wait" -lt 50 ]; do
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

# The session may have moved into a subdirectory of the worktree.
run_hook session-end "$hook_worktree/app" >/dev/null 2>&1
wait_for_archive
assert_equal "session-end archives after the branch is released" "1" "$(count_log archive)"
assert_true "session-end records the teardown" [ -f "$worktree_git_dir/workspace-claude-archived" ]
assert_false "session-end forgets the session branch after a complete archive" [ -f "$worktree_git_dir/workspace-claude-branch" ]
assert_false "session-end clears the running archive record" [ -f "$worktree_git_dir/workspace-claude-archiving" ]
assert_true "session-end logs archive output" grep -q 'Archive complete' "$worktree_git_dir/workspace-claude.log"

run_hook session-end "$hook_worktree" >/dev/null 2>&1
sleep 1
assert_equal "session-end archives only once" "1" "$(count_log archive)"

# Unarchive reattaches the branch and resumes; databases must come back even
# though the .workspace marker survived archive.
git -C "$hook_worktree" checkout -q claude/feature
run_hook session-start "$hook_worktree/app" resume >/dev/null 2>&1
assert_equal "session-start rebootstraps an unarchived worktree from a subdirectory" "2" "$(count_log setup)"
assert_false "session-start clears the teardown record" [ -f "$worktree_git_dir/workspace-claude-archived" ]
assert_false "session-start clears its setup record" [ -f "$worktree_git_dir/workspace-claude-bootstrapping" ]
run_hook session-start "$hook_worktree" >/dev/null 2>&1
assert_equal "session-start returns to bootstrap-once after recovery" "2" "$(count_log setup)"

# A failed archive is retried on the next archive, and the next start repairs
# the partly torn-down workspace with a full bootstrap.
git -C "$hook_worktree" checkout -q --detach
(export WORKSPACE_TEST_ARCHIVE_FAIL=1; run_hook session-end "$hook_worktree") >/dev/null 2>&1
wait_for_archive
assert_equal "failed archive was attempted" "2" "$(count_log archive)"
assert_true "failed archive keeps the session branch for retry" [ -f "$worktree_git_dir/workspace-claude-branch" ]
assert_true "failed archive still forces a full bootstrap" [ -f "$worktree_git_dir/workspace-claude-archived" ]
git -C "$hook_worktree" checkout -q claude/feature
run_hook session-start "$hook_worktree" resume >/dev/null 2>&1
assert_equal "session-start repairs a failed archive" "3" "$(count_log setup)"
git -C "$hook_worktree" checkout -q --detach
run_hook session-end "$hook_worktree" >/dev/null 2>&1
wait_for_archive
assert_equal "archive is retried on the next archive" "3" "$(count_log archive)"
assert_false "retried archive forgets the session branch" [ -f "$worktree_git_dir/workspace-claude-branch" ]

# Unarchiving while the background archive still runs waits for it, so the
# archive cannot drop databases after setup recreates them.
git -C "$hook_worktree" checkout -q claude/feature
run_hook session-start "$hook_worktree" resume >/dev/null 2>&1
assert_equal "setup before archive race" "4" "$(count_log setup)"
git -C "$hook_worktree" checkout -q --detach
(export WORKSPACE_TEST_ARCHIVE_SLEEP=2; run_hook session-end "$hook_worktree") >/dev/null 2>&1
git -C "$hook_worktree" checkout -q claude/feature
run_hook session-start "$hook_worktree" resume >/dev/null 2>&1
assert_equal "racing session-start waits for archive" "archive setup" "$(tail -2 "$hook_log" | tr '\n' ' ' | sed 's/ $//')"
assert_false "racing session-start leaves no teardown record" [ -f "$worktree_git_dir/workspace-claude-archived" ]

# Archiving while session start is still setting up waits for setup, so the
# archive cannot drop databases that setup creates afterward.
git -C "$hook_worktree" checkout -q --detach
run_hook session-end "$hook_worktree" >/dev/null 2>&1
wait_for_archive
assert_equal "archive before setup race" "5" "$(count_log archive)"
git -C "$hook_worktree" checkout -q claude/feature
(export WORKSPACE_TEST_SETUP_SLEEP=2; run_hook session-start "$hook_worktree" resume) >/dev/null 2>&1 &
setup_race_start=$!
setup_race_wait=0
while [ ! -f "$worktree_git_dir/workspace-claude-bootstrapping" ] && [ "$setup_race_wait" -lt 50 ]; do
  sleep 0.1
  setup_race_wait=$((setup_race_wait + 1))
done
git -C "$hook_worktree" checkout -q --detach
run_hook session-end "$hook_worktree" >/dev/null 2>&1
wait "$setup_race_start" 2>/dev/null || true
wait_for_archive
assert_equal "archive during setup waits for setup" "setup archive" "$(tail -2 "$hook_log" | tr '\n' ' ' | sed 's/ $//')"
assert_true "archive after setup marks the teardown" [ -f "$worktree_git_dir/workspace-claude-archived" ]
assert_false "archive after setup forgets the session branch" [ -f "$worktree_git_dir/workspace-claude-branch" ]

# A marker left by a killed archive whose PID now belongs to another process
# must not block session start or later archives.
git -C "$hook_worktree" checkout -q claude/feature
sleep 30 &
reused_pid=$!
printf '%s\n' "$reused_pid" > "$worktree_git_dir/workspace-claude-archiving"
run_hook session-start "$hook_worktree" resume >/dev/null 2>&1 &
reuse_start=$!
reuse_wait=0
while kill -0 "$reuse_start" 2>/dev/null && [ "$reuse_wait" -lt 50 ]; do
  sleep 0.2
  reuse_wait=$((reuse_wait + 1))
done
assert_false "session-start ignores a reused archive PID" sh -c 'kill -0 "$1" 2>/dev/null' sh "$reuse_start"
kill "$reuse_start" "$reused_pid" 2>/dev/null || true
wait "$reuse_start" "$reused_pid" 2>/dev/null || true
assert_false "session-start clears a marker with a reused PID" [ -f "$worktree_git_dir/workspace-claude-archiving" ]

# A later session that starts detached owns no branch, even though an earlier
# session recorded one.
assert_true "attached session recorded its branch" [ -f "$worktree_git_dir/workspace-claude-branch" ]
git -C "$hook_worktree" checkout -q --detach
run_hook session-start "$hook_worktree" >/dev/null 2>&1
assert_false "detached session-start clears a stale branch" [ -f "$worktree_git_dir/workspace-claude-branch" ]
run_hook session-end "$hook_worktree" >/dev/null 2>&1
sleep 1
assert_equal "stale branch does not trigger archive" "6" "$(count_log archive)"

# Quitting looks exactly like archiving for a session that resumed detached,
# so it is never archived automatically; leaving databases is safer.
git -C "$hook_worktree" checkout -q claude/feature
run_hook session-start "$hook_worktree" >/dev/null 2>&1
git -C "$hook_worktree" checkout -q --detach
run_hook session-start "$hook_worktree" resume >/dev/null 2>&1
assert_false "detached resume owns no branch" [ -f "$worktree_git_dir/workspace-claude-branch" ]
run_hook session-end "$hook_worktree" >/dev/null 2>&1
sleep 1
assert_equal "detached resumed session is not archived" "6" "$(count_log archive)"

# Conductor-family managers own setup and archive for their worktrees.
git -C "$hook_worktree" checkout -q claude/feature
run_hook session-start "$hook_worktree" >/dev/null 2>&1
git -C "$hook_worktree" checkout -q --detach
(export CONDUCTOR_ROOT_PATH="$hook_root" CONDUCTOR_WORKSPACE_NAME="managed"
  run_hook session-end "$hook_worktree") >/dev/null 2>&1
sleep 1
assert_equal "session-end leaves managed workspaces alone" "6" "$(count_log archive)"
git -C "$hook_worktree" checkout -q claude/feature

# Worktrees that start detached (Codex) are never archived by Claude hooks.
run_hook session-start "$codex_worktree" >/dev/null 2>&1
run_hook session-end "$codex_worktree" >/dev/null 2>&1
sleep 1
codex_git_dir=$(git -C "$codex_worktree" rev-parse --absolute-git-dir)
assert_false "detached-at-start worktree has no session branch" [ -f "$codex_git_dir/workspace-claude-branch" ]
assert_equal "detached-at-start worktree is not archived" "6" "$(count_log archive)"

# A worktree archived by hand (no hook teardown record) is unregistered, so
# the next session start sets it up again instead of skipping it.
setups_before=$(count_log setup)
(cd "$hook_worktree" && PATH="$fake_bin:$PATH" WORKSPACE_TEST_LOG="$hook_log" \
  sh "$WORKSPACE_HOME/lib/archive.sh") >/dev/null 2>&1
run_hook session-start "$hook_worktree" resume >/dev/null 2>&1
assert_equal "session-start sets up a worktree archived by hand" "$((setups_before + 1))" "$(count_log setup)"

# A stale setup marker naming an unrelated process does not hold up archive,
# even when that process's command line mentions the session-start hook.
sh -c 'sleep 30' "claude_hook.sh session-start" &
impostor_pid=$!
printf '%s\n' "$impostor_pid" > "$worktree_git_dir/workspace-claude-bootstrapping"
archives_before=$(count_log archive)
git -C "$hook_worktree" checkout -q --detach
run_hook session-end "$hook_worktree" >/dev/null 2>&1
wait_for_archive
assert_equal "archive ignores a setup marker naming another process" "$((archives_before + 1))" "$(count_log archive)"
kill "$impostor_pid" 2>/dev/null || true
wait "$impostor_pid" 2>/dev/null || true

# If Claude Code stops the session-start hook mid-setup, the setup keeps
# running and the archive still waits for it.
git -C "$hook_worktree" checkout -q claude/feature
(export WORKSPACE_TEST_SETUP_SLEEP=3; run_hook session-start "$hook_worktree" resume) >/dev/null 2>&1 &
killed_start=$!
killed_wait=0
while [ ! -s "$worktree_git_dir/workspace-claude-bootstrapping" ] && [ "$killed_wait" -lt 50 ]; do
  sleep 0.1
  killed_wait=$((killed_wait + 1))
done
setup_pid=$(cat "$worktree_git_dir/workspace-claude-bootstrapping")
hook_pid=$(ps -o ppid= -p "$setup_pid" | tr -d ' ')
kill -TERM "$hook_pid" 2>/dev/null || true
sleep 0.3
assert_true "killed hook leaves the running setup's marker" [ -f "$worktree_git_dir/workspace-claude-bootstrapping" ]
git -C "$hook_worktree" checkout -q --detach
run_hook session-end "$hook_worktree" >/dev/null 2>&1
wait "$killed_start" 2>/dev/null || true
wait_for_archive
assert_equal "archive waits for setup orphaned by a killed hook" "setup archive" "$(tail -2 "$hook_log" | tr '\n' ' ' | sed 's/ $//')"

# An overlapping session start replaced the setup marker; finishing setup
# must not remove the other session's marker.
git -C "$hook_worktree" checkout -q claude/feature
(export WORKSPACE_TEST_SETUP_SLEEP=2; run_hook session-start "$hook_worktree" resume) >/dev/null 2>&1 &
overlap_start=$!
overlap_wait=0
while [ ! -s "$worktree_git_dir/workspace-claude-bootstrapping" ] && [ "$overlap_wait" -lt 50 ]; do
  sleep 0.1
  overlap_wait=$((overlap_wait + 1))
done
printf '424242\n' > "$worktree_git_dir/workspace-claude-bootstrapping"
wait "$overlap_start" 2>/dev/null || true
assert_equal "finished setup keeps another session's marker" "424242" "$(cat "$worktree_git_dir/workspace-claude-bootstrapping" 2>/dev/null)"
rm -f "$worktree_git_dir/workspace-claude-bootstrapping"

report "claude-hook"
