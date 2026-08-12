#!/bin/sh
# Tests for linked-worktree registration and stale-resource pruning.

cd "$(dirname "$0")"
. ./test_helper.sh
. "$WORKSPACE_HOME/lib/registry.sh"

unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME 2>/dev/null || true
unset WORKSPACE_PORT 2>/dev/null || true

git_root="$TEST_TMP/registry-root"
CODEX_HOME="$TEST_TMP/codex"
git_worktree="$CODEX_HOME/worktrees/registry-worktree"
mkdir -p "$git_root/bin" "$git_root/config" "$CODEX_HOME/worktrees"
printf 'development:\n  database: app_development\n' > "$git_root/config/database.yml"
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
assert_equal "registered port accessor decodes record" "51230" "$(registered_workspace_port)"
assert_equal "git port derivation reuses registration" "51230" "$(derive_workspace_port 3000)"
WORKSPACE_PORT=51300
assert_equal "explicit port overrides Git registration" "51300" "$(derive_workspace_port 3000)"
unset WORKSPACE_PORT
load_registered_workspace "$registry_entry"
assert_equal "registered path accessor decodes record" "$git_worktree" "$WORKSPACE_REGISTERED_PATH"

# Explicit port blocks are user intent, so a second linked worktree must fail
# before sweeping or starting on a block already reserved by another worktree.
conflicting_worktree="$CODEX_HOME/worktrees/registry-conflict"
git -C "$git_root" worktree add -q --detach "$conflicting_worktree"
conflicting_worktree=$(cd "$conflicting_worktree" && pwd -P)
collision_bin="$TEST_TMP/collision-bin"
collision_sweep_log="$TEST_TMP/collision-sweep.log"
collision_run_log="$TEST_TMP/collision-run.log"
mkdir -p "$collision_bin" "$conflicting_worktree/bin"
cat > "$collision_bin/lsof" <<'EOF'
#!/bin/sh
printf 'swept\n' >> "$WORKSPACE_TEST_SWEEP_LOG"
exit 1
EOF
chmod +x "$collision_bin/lsof"
cat > "$conflicting_worktree/bin/foreman" <<'EOF'
#!/bin/sh
printf 'started\n' > "$WORKSPACE_TEST_RUN_LOG"
EOF
chmod +x "$conflicting_worktree/bin/foreman"

cd "$conflicting_worktree"
resolve_workspace
sanitize_workspace_name
conflicting_registry_entry="$git_root/.git/workspace/registry/$WORKSPACE_NAME.record"
assert_false "overlapping explicit port block aborts run" env PATH="$collision_bin:$PATH" WORKSPACE_PORT=51235 WORKSPACE_TEST_SWEEP_LOG="$collision_sweep_log" WORKSPACE_TEST_RUN_LOG="$collision_run_log" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_false "explicit port collision creates no registration" [ -e "$conflicting_registry_entry" ]
assert_false "explicit port collision does not sweep ports" [ -e "$collision_sweep_log" ]
assert_false "explicit port collision does not start processes" [ -e "$collision_run_log" ]
assert_false "invalid explicit port block aborts run" env PATH="$collision_bin:$PATH" WORKSPACE_PORT=65535 WORKSPACE_TEST_SWEEP_LOG="$collision_sweep_log" WORKSPACE_TEST_RUN_LOG="$collision_run_log" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_false "invalid explicit port creates no registration" [ -e "$conflicting_registry_entry" ]
assert_false "invalid explicit port does not sweep ports" [ -e "$collision_sweep_log" ]
assert_false "invalid explicit port does not start processes" [ -e "$collision_run_log" ]

cat > "$conflicting_worktree/bin/setup" <<'EOF'
#!/bin/sh
printf 'setup\n' >> "$WORKSPACE_TEST_BOOTSTRAP_LOG"
EOF
cat > "$conflicting_worktree/bin/rails" <<'EOF'
#!/bin/sh
printf 'rails:%s\n' "$*" >> "$WORKSPACE_TEST_BOOTSTRAP_LOG"
EOF
chmod +x "$conflicting_worktree/bin/setup" "$conflicting_worktree/bin/rails"
collision_bootstrap_log="$TEST_TMP/collision-bootstrap.log"
assert_false "overlapping explicit port block aborts bootstrap before setup" env WORKSPACE_PORT=51235 WORKSPACE_TEST_BOOTSTRAP_LOG="$collision_bootstrap_log" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_false "bootstrap collision has no project side effects" [ -e "$collision_bootstrap_log" ]
assert_false "bootstrap collision writes no stable marker" [ -e .workspace ]
assert_false "invalid explicit port aborts bootstrap before setup" env WORKSPACE_PORT=65535 WORKSPACE_TEST_BOOTSTRAP_LOG="$collision_bootstrap_log" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_false "invalid bootstrap port has no project side effects" [ -e "$collision_bootstrap_log" ]
assert_false "invalid bootstrap port writes no stable marker" [ -e .workspace ]

cd "$git_worktree"
resolve_workspace
sanitize_workspace_name
WORKSPACE_NAME="$registered_name"

WORKSPACE_NAME="feature/foo"
punctuation_registry_entry=$(workspace_registry_entry)
register_workspace "51260"
assert_true "punctuation identity is registered with an opaque record key" [ -f "$punctuation_registry_entry" ]
assert_equal "punctuation identity remains exact in its record" "feature/foo" "$(sed -n '1p' "$punctuation_registry_entry")"
assert_equal "punctuation identity reuses its registered port" "51260" "$(registered_workspace_port)"
unregister_workspace
assert_false "punctuation identity unregisters its opaque record" [ -e "$punctuation_registry_entry" ]
WORKSPACE_NAME="$registered_name"

default_record="$git_root/.git/workspace/registry/default.record"
printf 'default\n%s\n%s\n51290\n' "$git_root" "$git_worktree" > "$default_record"
assert_false "registry rejects reserved default workspace identity" load_registered_workspace "$default_record"
rm "$default_record"

WORKSPACE_NAME="default"
assert_false "registry entry path rejects reserved default identity" workspace_registry_entry
WORKSPACE_NAME="$registered_name"

WORKSPACE_NAME="second-worktree"
register_workspace "51235"
second_registry_entry="$git_root/.git/workspace/registry/second-worktree.record"
assert_equal "automatic registration avoids an overlapping port block" "51245" "$(sed -n '4p' "$second_registry_entry")"
unregister_workspace
WORKSPACE_NAME="$registered_name"

claimed_entry="$registry_entry.pruning-test"
mv "$registry_entry" "$claimed_entry"
register_workspace "51230"
unregister_workspace "$claimed_entry"
assert_true "unregistering a claim preserves republished record" [ -f "$registry_entry" ]

cd "$git_root"
nonregular_target="$TEST_TMP/nonregular-record-target"
nonregular_entry="$git_root/.git/workspace/registry/nonregular.record"
printf 'nonregular\n%s\n%s\n51280\n' "$git_root" "$TEST_TMP/removed-nonregular-worktree" > "$nonregular_target"
ln -s "$nonregular_target" "$nonregular_entry"
sh "$WORKSPACE_HOME/lib/prune.sh" --quiet
assert_true "live registered worktree is preserved" [ -f "$registry_entry" ]
assert_true "prune leaves non-regular registry records untouched" [ -L "$nonregular_entry" ]
rm "$nonregular_entry"

orphaned_claim="$registry_entry.pruning.99999999"
mv "$registry_entry" "$orphaned_claim"
sh "$WORKSPACE_HOME/lib/prune.sh" --quiet
assert_true "orphaned claim is restored and preserved" [ -f "$registry_entry" ]
assert_false "orphaned claim is removed" [ -f "$orphaned_claim" ]

# `workspace run` must publish a reservation even when bootstrap has not done
# so yet, before it sweeps any ports.
rm "$registry_entry"
run_fake_bin="$TEST_TMP/run-bin"
run_log="$TEST_TMP/run.log"
mkdir -p "$run_fake_bin" "$git_worktree/bin"
cat > "$run_fake_bin/lsof" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$run_fake_bin/lsof"
cat > "$git_worktree/bin/foreman" <<'EOF'
#!/bin/sh
printf '%s\n' "$PORT" > "$WORKSPACE_TEST_RUN_LOG"
EOF
chmod +x "$git_worktree/bin/foreman"
cd "$git_worktree"
PATH="$run_fake_bin:$PATH" CODEX_HOME="$CODEX_HOME" CONDUCTOR_PORT=51230 WORKSPACE_TEST_RUN_LOG="$run_log" sh "$WORKSPACE_HOME/lib/run.sh"
assert_true "run registers an unbootstrapped Git worktree" [ -f "$registry_entry" ]
assert_equal "run uses its registered port" "$(sed -n '4p' "$registry_entry")" "$(cat "$run_log")"

# Manual Git archive keeps the record when Rails reports a database failure,
# allowing prune or a later archive to retry.
mkdir -p config
printf 'development:\n  database: app_development\n' > config/database.yml
cat > bin/rails <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x bin/rails
assert_false "manual archive reports database failures" env PATH="$run_fake_bin:$PATH" CODEX_HOME="$CODEX_HOME" sh "$WORKSPACE_HOME/lib/archive.sh"
assert_true "manual archive failure preserves registry" [ -f "$registry_entry" ]
cd "$git_root"

# Lock files created by older workspace versions are recovered after their
# owner exits, preserving upgrade compatibility.
mkdir "$git_root/.git/workspace/prune.lock"
printf '%s\n' "99999999" > "$git_root/.git/workspace/prune.lock/pid"
WORKSPACE_REGISTRY_LOCK_ATTEMPTS=1
export WORKSPACE_REGISTRY_LOCK_ATTEMPTS
assert_true "dead legacy lock is upgraded" wait_for_workspace_registry_lock
assert_true "upgraded lock publishes owner atomically" [ "$(readlink "$git_root/.git/workspace/prune.lock")" = "$$" ]
release_workspace_registry_lock
unset WORKSPACE_REGISTRY_LOCK_ATTEMPTS

sleep 30 &
other_lock_owner=$!
ln -s "$other_lock_owner" "$git_root/.git/workspace/prune.lock"
WORKSPACE_REGISTRY_LOCK_ATTEMPTS=1
export WORKSPACE_REGISTRY_LOCK_ATTEMPTS
assert_false "registration cannot publish while prune owns lock" register_workspace "59990"
unset WORKSPACE_REGISTRY_LOCK_ATTEMPTS
assert_equal "blocked registration leaves record unchanged" "51230" "$(sed -n '4p' "$registry_entry")"
kill "$other_lock_owner"
wait "$other_lock_owner" 2>/dev/null || true
rm "$git_root/.git/workspace/prune.lock"

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

invalid_port_entry="$git_root/.git/workspace/registry/invalid-port.record"
invalid_port_lsof_log="$TEST_TMP/invalid-port-lsof.log"
printf 'invalid-port\n%s\n%s\n65535\n' "$git_root" "$TEST_TMP/removed-invalid-port-worktree" > "$invalid_port_entry"
PATH="$fake_bin:$PATH" WORKSPACE_TEST_LSOF_LOG="$invalid_port_lsof_log" WORKSPACE_TEST_ARCHIVE_HOOK_LOG="$archive_hook_log" WORKSPACE_TEST_PRUNE_LOG="$prune_log" sh "$WORKSPACE_HOME/lib/archive.sh" --registry-entry "$invalid_port_entry" >/dev/null 2>&1
assert_false "invalid registered port is not swept during archive" [ -e "$invalid_port_lsof_log" ]
assert_false "successful archive removes an invalid-port registry record" [ -e "$invalid_port_entry" ]
assert_true "invalid registered port does not prevent database cleanup" grep -q '^development:_invalid-port:db:drop$' "$prune_log"

ln -s "$$" "$git_root/.git/workspace/prune.lock"
PATH="$fake_bin:$PATH" WORKSPACE_TEST_PRUNE_LOG="$prune_log" sh "$WORKSPACE_HOME/lib/prune.sh"
assert_true "overlapping prune leaves registry to lock owner" [ -f "$registry_entry" ]
rm "$git_root/.git/workspace/prune.lock"

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

ln -s "99999999" "$git_root/.git/workspace/prune.lock"
PATH="$fake_bin:$PATH" WORKSPACE_TEST_LSOF_LOG="$lsof_log" WORKSPACE_TEST_ARCHIVE_HOOK_LOG="$archive_hook_log" WORKSPACE_TEST_DB_DROP_FAIL=1 WORKSPACE_TEST_PRUNE_LOG="$prune_log" sh "$WORKSPACE_HOME/lib/prune.sh"

assert_true "failed database cleanup preserves registry" [ -f "$registry_entry" ]
assert_false "stale prune lock recovered" [ -L "$git_root/.git/workspace/prune.lock" ]

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
