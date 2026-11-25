#!/bin/sh
# Tests for WORKSPACE_SKIP_PRUNE: bootstrap, run, and the deferred SessionEnd
# prune leave removed worktrees' records alone; an explicit prune still runs.

cd "$(dirname "$0")"
. ./test_helper.sh

unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME 2>/dev/null || true
unset WORKSPACE_PORT 2>/dev/null || true

git_root="$TEST_TMP/skip-prune-root"
mkdir -p "$git_root/bin" "$git_root/config"
printf 'development:\n  database: app_development\ntest:\n  database: app_test\n' > "$git_root/config/database.yml"
cat > "$git_root/bin/rails" <<'EOF'
#!/bin/sh
[ "$1" = runner ] && { echo workspace-suffix-checked; exit 0; }
printf '%s:%s:%s\n' "$RAILS_ENV" "$WORKSPACE_DB_SUFFIX" "$*" >> "$WORKSPACE_TEST_RAILS_LOG"
EOF
cat > "$git_root/bin/foreman" <<'EOF'
#!/bin/sh
printf 'started\n' >> "$WORKSPACE_TEST_RAILS_LOG"
EOF
chmod +x "$git_root/bin/rails" "$git_root/bin/foreman"
printf 'web: true\n' > "$git_root/Procfile.dev"
commit_git_repo "$git_root"
lane="$TEST_TMP/skip-prune-lane"
git -C "$git_root" worktree add -q --detach "$lane"
git_root=$(cd "$git_root" && pwd -P)
lane=$(cd "$lane" && pwd -P)

fake_bin="$TEST_TMP/skip-prune-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/lsof" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$fake_bin/nohup" <<'EOF'
#!/bin/sh
printf 'deferred\n' >> "$WORKSPACE_TEST_DEFERRED_LOG"
EOF
chmod +x "$fake_bin/lsof" "$fake_bin/nohup"

registry="$git_root/.git/workspace/registry"
stale_entry="$registry/gone.record"
rails_log="$TEST_TMP/skip-prune-rails.log"
deferred_log="$TEST_TMP/skip-prune-deferred.log"

# A record for a worktree that no longer exists, which prune would archive.
write_stale_record() {
  mkdir -p "$registry"
  printf 'gone\n%s\n%s\n51700\n' "$git_root" "$TEST_TMP/removed-gone-worktree" > "$stale_entry"
  : > "$rails_log"
}

workspace_command() {
  (cd "$lane" && env PATH="$fake_bin:$PATH" WORKSPACE_TEST_RAILS_LOG="$rails_log" \
    WORKSPACE_TEST_DEFERRED_LOG="$deferred_log" "$@" 2>&1)
}

for command in bootstrap run; do
  write_stale_record
  output=$(workspace_command env WORKSPACE_SKIP_PRUNE=1 sh "$WORKSPACE_HOME/lib/$command.sh")
  assert_equal "$command with WORKSPACE_SKIP_PRUNE=1 succeeds" "0" "$?"
  assert_true "$command with WORKSPACE_SKIP_PRUNE=1 keeps a removed worktree's record" [ -f "$stale_entry" ]
  assert_false "$command with WORKSPACE_SKIP_PRUNE=1 drops no removed worktree's databases" grep -q ':_gone:db:drop' "$rails_log"
  assert_true "$command with WORKSPACE_SKIP_PRUNE=1 says cleanup was skipped" \
    sh -c 'printf "%s\n" "$1" | grep -q "WORKSPACE_SKIP_PRUNE=1 — skipping removed-worktree cleanup"' _ "$output"

  write_stale_record
  output=$(workspace_command sh "$WORKSPACE_HOME/lib/$command.sh")
  assert_equal "$command without WORKSPACE_SKIP_PRUNE succeeds" "0" "$?"
  assert_false "$command without WORKSPACE_SKIP_PRUNE prunes a removed worktree's record" [ -f "$stale_entry" ]
  assert_true "$command without WORKSPACE_SKIP_PRUNE drops a removed worktree's databases" grep -q '^development:_gone:db:drop$' "$rails_log"
  assert_false "$command without WORKSPACE_SKIP_PRUNE prints no skip notice" \
    sh -c 'printf "%s\n" "$1" | grep -q "WORKSPACE_SKIP_PRUNE"' _ "$output"
done

# The SessionEnd hook's deferred prune is automatic too. It schedules cleanup
# in the background; that job inherits fd 9, so each command substitution
# below ends only after any job it started has written to the log.
: > "$deferred_log"
output=$(workspace_command env WORKSPACE_SKIP_PRUNE=1 sh "$WORKSPACE_HOME/lib/prune.sh" --deferred 9>&1)
assert_equal "deferred prune with WORKSPACE_SKIP_PRUNE=1 schedules nothing" "" "$(cat "$deferred_log")"
output=$(workspace_command sh "$WORKSPACE_HOME/lib/prune.sh" --deferred 9>&1)
assert_equal "deferred prune without WORKSPACE_SKIP_PRUNE schedules cleanup" "deferred" "$(cat "$deferred_log")"

# The opt-out is read from the caller's environment, like bootstrap and the
# SessionEnd hook, so a project .env cannot turn it on for run alone.
write_stale_record
printf 'WORKSPACE_SKIP_PRUNE=1\n' > "$lane/.env"
workspace_command sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null
assert_false "run ignores WORKSPACE_SKIP_PRUNE from the project .env" [ -f "$stale_entry" ]
rm -f "$lane/.env"

# An explicit prune is a request, so the variable does not stop it.
write_stale_record
workspace_command env WORKSPACE_SKIP_PRUNE=1 "$WORKSPACE_HOME/bin/workspace" prune >/dev/null
assert_false "explicit prune with WORKSPACE_SKIP_PRUNE=1 still prunes" [ -f "$stale_entry" ]
assert_true "explicit prune with WORKSPACE_SKIP_PRUNE=1 still drops databases" grep -q '^development:_gone:db:drop$' "$rails_log"

git -C "$git_root" worktree remove -f "$lane"

report "workspace skip prune"
