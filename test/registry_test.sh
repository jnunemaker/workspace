#!/bin/sh
# Tests for linked-worktree registration and stale-resource pruning.

cd "$(dirname "$0")"
. ./test_helper.sh
. "$WORKSPACE_HOME/lib/registry.sh"

unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME 2>/dev/null || true

git_root="$TEST_TMP/registry-root"
CODEX_HOME="$TEST_TMP/codex"
git_worktree="$CODEX_HOME/worktrees/registry-worktree"
mkdir -p "$git_root/bin" "$git_root/config" "$CODEX_HOME/worktrees"
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
sanitize_workspace_name
registered_name="$WORKSPACE_NAME"
register_workspace "51230"
registry_entry="$git_root/.git/workspace/registry/$registered_name.record"

assert_true "git workspace registration created" [ -f "$registry_entry" ]
assert_equal "registered name recorded" "$registered_name" "$(sed -n '1p' "$registry_entry")"
assert_equal "registered root recorded" "$git_root" "$(sed -n '2p' "$registry_entry")"
assert_equal "registered worktree path recorded" "$git_worktree" "$(sed -n '3p' "$registry_entry")"
assert_equal "registered port recorded" "51230" "$(sed -n '4p' "$registry_entry")"
assert_equal "git port derivation reuses registration" "51230" "$(derive_workspace_port 3000)"

WORKSPACE_NAME="second-worktree"
register_workspace "51230"
second_registry_entry="$git_root/.git/workspace/registry/second-worktree.record"
assert_equal "registration avoids an occupied port block" "51240" "$(sed -n '4p' "$second_registry_entry")"
unregister_workspace
WORKSPACE_NAME="$registered_name"

claimed_entry="$registry_entry.pruning-test"
mv "$registry_entry" "$claimed_entry"
register_workspace "51230"
unregister_workspace "$claimed_entry"
assert_true "unregistering a claim preserves republished record" [ -f "$registry_entry" ]

cd "$git_root"
sh "$WORKSPACE_HOME/lib/prune.sh" --quiet
assert_true "live registered worktree is preserved" [ -f "$registry_entry" ]

orphaned_claim="$registry_entry.pruning.99999999"
mv "$registry_entry" "$orphaned_claim"
sh "$WORKSPACE_HOME/lib/prune.sh" --quiet
assert_true "orphaned claim is restored and preserved" [ -f "$registry_entry" ]
assert_false "orphaned claim is removed" [ -f "$orphaned_claim" ]

sleep 30 &
other_lock_owner=$!
mkdir "$git_root/.git/workspace/prune.lock"
printf '%s\n' "$other_lock_owner" > "$git_root/.git/workspace/prune.lock/pid"
WORKSPACE_REGISTRY_LOCK_ATTEMPTS=1
export WORKSPACE_REGISTRY_LOCK_ATTEMPTS
assert_false "registration cannot publish while prune owns lock" register_workspace "59990"
unset WORKSPACE_REGISTRY_LOCK_ATTEMPTS
assert_equal "blocked registration leaves record unchanged" "51230" "$(sed -n '4p' "$registry_entry")"
kill "$other_lock_owner"
wait "$other_lock_owner" 2>/dev/null || true
rm "$git_root/.git/workspace/prune.lock/pid"
rmdir "$git_root/.git/workspace/prune.lock"

# Removing the Git worktree makes the registry entry stale. Prune must clean
# the isolated databases from the surviving root checkout, then unregister it.
git worktree remove -f "$git_worktree"
prune_log="$TEST_TMP/prune.log"
fake_bin="$TEST_TMP/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/lsof" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WORKSPACE_TEST_LSOF_LOG"
exit 1
EOF
chmod +x "$fake_bin/lsof"
lsof_log="$TEST_TMP/lsof.log"
cat > bin/rails <<'EOF'
#!/bin/sh
printf '%s:%s:%s\n' "$RAILS_ENV" "$WORKSPACE_DB_SUFFIX" "$*" >> "$WORKSPACE_TEST_PRUNE_LOG"
[ -n "${WORKSPACE_TEST_DB_DROP_FAIL:-}" ] && exit 1
exit 0
EOF
chmod +x bin/rails
archive_hook_log="$TEST_TMP/archive-hook.log"
cat > bin/workspace-archive-hook <<'EOF'
#!/bin/sh
printf '%s:%s\n' "$(pwd -P)" "$WORKSPACE_DB_SUFFIX" >> "$WORKSPACE_TEST_ARCHIVE_HOOK_LOG"
EOF
chmod +x bin/workspace-archive-hook

mkdir "$git_root/.git/workspace/prune.lock"
printf '%s\n' "$$" > "$git_root/.git/workspace/prune.lock/pid"
PATH="$fake_bin:$PATH" WORKSPACE_TEST_PRUNE_LOG="$prune_log" sh "$WORKSPACE_HOME/lib/prune.sh"
assert_true "overlapping prune leaves registry to lock owner" [ -f "$registry_entry" ]
rm "$git_root/.git/workspace/prune.lock/pid"
rmdir "$git_root/.git/workspace/prune.lock"

# A failed authoritative Git query must leave the record untouched.
fake_git_bin="$TEST_TMP/git-bin"
mkdir -p "$fake_git_bin"
cat > "$fake_git_bin/git" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "worktree" ] && [ "${4:-}" = "list" ]; then
  exit 1
fi
exec "$WORKSPACE_TEST_REAL_GIT" "$@"
EOF
chmod +x "$fake_git_bin/git"
WORKSPACE_TEST_REAL_GIT=$(command -v git) PATH="$fake_git_bin:$PATH" sh "$WORKSPACE_HOME/lib/prune.sh" --quiet
assert_true "Git query failure preserves registry" [ -f "$registry_entry" ]

mkdir "$git_root/.git/workspace/prune.lock"
printf '%s\n' "99999999" > "$git_root/.git/workspace/prune.lock/pid"
PATH="$fake_bin:$PATH" WORKSPACE_TEST_LSOF_LOG="$lsof_log" WORKSPACE_TEST_ARCHIVE_HOOK_LOG="$archive_hook_log" WORKSPACE_TEST_DB_DROP_FAIL=1 WORKSPACE_TEST_PRUNE_LOG="$prune_log" sh "$WORKSPACE_HOME/lib/prune.sh"

assert_true "failed database cleanup preserves registry" [ -f "$registry_entry" ]
assert_false "stale prune lock recovered" [ -d "$git_root/.git/workspace/prune.lock" ]

PATH="$fake_bin:$PATH" WORKSPACE_TEST_LSOF_LOG="$lsof_log" WORKSPACE_TEST_ARCHIVE_HOOK_LOG="$archive_hook_log" WORKSPACE_TEST_PRUNE_LOG="$prune_log" sh "$WORKSPACE_HOME/lib/prune.sh"

assert_false "stale registry entry removed" [ -f "$registry_entry" ]
assert_true "prune drops development database" grep -q "development:_${registered_name}:db:drop" "$prune_log"
assert_true "prune drops test database" grep -q "test:_${registered_name}:db:drop" "$prune_log"
assert_true "port sweep uses isolated lsof stub" [ "$(wc -l < "$lsof_log" | tr -d ' ')" -eq 20 ]
assert_true "archive hook runs from surviving root" grep -q "^${git_root}:_${registered_name}$" "$archive_hook_log"

# Registration is intentionally limited to generic Git worktrees; existing
# providers continue to own their lifecycle state.
SUPERSET_ROOT_PATH="/superset/root"
SUPERSET_WORKSPACE_NAME="superset-ws"
resolve_workspace
register_workspace "50000"
assert_false "superset workspace is not registered" [ -f "$git_root/.git/workspace/registry/superset-ws.record" ]

report "workspace registry"
