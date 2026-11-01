#!/bin/sh
# Lifecycle commands stop when signalled instead of continuing without the lock.

cd "$(dirname "$0")"
. ./test_helper.sh

unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_PORT
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME SUPERSET_PORT
unset CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME CONDUCTOR_PORT
unset WORKSPACE_DB_SUFFIX
export WORKSPACE_PORT=51250

root="$TEST_TMP/signal-root"
mkdir -p "$root/bin" "$root/config"
touch "$root/config/database.yml"
cat > "$root/bin/rails" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$WORKSPACE_TEST_RAILS_LOG"
case "$*" in
  runner*) echo workspace-suffix-checked ;;
esac
SCRIPT
# Holds a lifecycle command inside a project hook until the test signals it.
cat > "$root/bin/hold-hook" <<'SCRIPT'
#!/bin/sh
touch "$WORKSPACE_TEST_DIR/hook-started"
until [ -f "$WORKSPACE_TEST_DIR/hook-release" ]; do sleep 0.1; done
SCRIPT
chmod +x "$root/bin/rails" "$root/bin/hold-hook"
commit_git_repo "$root"

worktree="$TEST_TMP/signal-worktree"
git -C "$root" worktree add -q "$worktree" -b signal-worktree

export WORKSPACE_TEST_DIR="$TEST_TMP"
export WORKSPACE_TEST_RAILS_LOG="$TEST_TMP/rails.log"
lock="$root/.git/workspace/prune.lock"

# Run a lib/ command with `$hook` holding it, signal it, then let the hook end.
signal_during_hook() {
  _signal_hook="$1"
  _signal_command="$2"
  rm -f "$TEST_TMP/hook-started" "$TEST_TMP/hook-release"
  : > "$WORKSPACE_TEST_RAILS_LOG"
  cp "$worktree/bin/hold-hook" "$worktree/bin/$_signal_hook"
  sh "$WORKSPACE_HOME/lib/$_signal_command.sh" >/dev/null 2>&1 &
  _signal_pid=$!
  wait_until [ -f "$TEST_TMP/hook-started" ]
  kill -TERM "$_signal_pid"
  sleep 0.2
  touch "$TEST_TMP/hook-release"
  _signal_status=0
  wait "$_signal_pid" || _signal_status=$?
  rm -f "$worktree/bin/$_signal_hook"
}

cd "$worktree"

signal_during_hook workspace-setup-hook bootstrap
assert_equal "signalled bootstrap exits with the signal's status" "143" "$_signal_status"
assert_false "signalled bootstrap prepares no database" grep -q 'db:prepare' "$WORKSPACE_TEST_RAILS_LOG"
assert_false "signalled bootstrap writes no .workspace marker" [ -e .workspace ]
assert_false "signalled bootstrap releases the lock" [ -L "$lock" ]

sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1

signal_during_hook workspace-archive-hook archive
assert_equal "signalled archive exits with the signal's status" "143" "$_signal_status"
assert_false "signalled archive drops no database" grep -q 'db:drop' "$WORKSPACE_TEST_RAILS_LOG"
assert_true "signalled archive keeps its registration" [ -n "$(ls "$root/.git/workspace/registry")" ]
assert_false "signalled archive releases the lock" [ -L "$lock" ]

# Prune is signalled during the cleanup it runs for a worktree that is gone,
# and restores the claimed record on its next run.
cd "$root"
cp "$root/bin/hold-hook" "$root/bin/workspace-archive-hook"
git -C "$root" worktree remove --force "$worktree"
rm -f "$TEST_TMP/hook-started" "$TEST_TMP/hook-release"
: > "$WORKSPACE_TEST_RAILS_LOG"
sh "$WORKSPACE_HOME/lib/prune.sh" >/dev/null 2>&1 &
_signal_pid=$!
wait_until [ -f "$TEST_TMP/hook-started" ]
kill -TERM "$_signal_pid"
sleep 0.2
touch "$TEST_TMP/hook-release"
_signal_status=0
wait "$_signal_pid" || _signal_status=$?
assert_equal "signalled prune exits with the signal's status" "143" "$_signal_status"
assert_false "signalled prune releases the lock" [ -L "$lock" ]

report "signals"
