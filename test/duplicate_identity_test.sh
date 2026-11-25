#!/bin/sh
# Tests that two live Git worktrees whose names sanitize to one identity never
# share a registry record, and so never share databases and ports.

cd "$(dirname "$0")"
. ./test_helper.sh
. "$WORKSPACE_HOME/lib/registry.sh"

unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME 2>/dev/null || true
unset WORKSPACE_PORT 2>/dev/null || true

git_root="$TEST_TMP/duplicate-root"
mkdir -p "$git_root/bin" "$git_root/config"
printf 'development:\n  database: app_development\ntest:\n  database: app_test\n' > "$git_root/config/database.yml"
cat > "$git_root/bin/setup" <<'EOF'
#!/bin/sh
printf 'setup:%s\n' "$(pwd -P)" >> "$WORKSPACE_TEST_LOG"
EOF
cat > "$git_root/bin/rails" <<'EOF'
#!/bin/sh
[ "$1" = runner ] && { echo workspace-suffix-checked; exit 0; }
printf 'rails:%s:%s\n' "$(pwd -P)" "$*" >> "$WORKSPACE_TEST_LOG"
EOF
cat > "$git_root/bin/foreman" <<'EOF'
#!/bin/sh
printf 'foreman:%s\n' "$(pwd -P)" >> "$WORKSPACE_TEST_LOG"
EOF
chmod +x "$git_root/bin/setup" "$git_root/bin/rails" "$git_root/bin/foreman"
printf 'web: true\n' > "$git_root/Procfile.dev"
commit_git_repo "$git_root"
git_root=$(cd "$git_root" && pwd -P)

fake_bin="$TEST_TMP/duplicate-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/lsof" <<'EOF'
#!/bin/sh
printf 'lsof:%s\n' "$*" >> "$WORKSPACE_TEST_LOG"
exit 1
EOF
chmod +x "$fake_bin/lsof"
log="$TEST_TMP/duplicate.log"

add_worktree() {
  git -C "$git_root" worktree add -q --detach "$TEST_TMP/$1"
  (cd "$TEST_TMP/$1" && pwd -P)
}

lifecycle() {
  (cd "$1" && shift && env PATH="$fake_bin:$PATH" WORKSPACE_TEST_LOG="$log" "$@")
}

# Git worktree IDs are cut to 40 characters, so these two share one identity.
first=$(add_worktree "feature-implement-the-new-billing-system-part-1")
second=$(add_worktree "feature-implement-the-new-billing-system-part-2")
shared_entry="$git_root/.git/workspace/registry/feature-implement-the-new-billing-system.record"

lifecycle "$first" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "first long-named worktree bootstraps" "0" "$?"
assert_equal "first long-named worktree owns the shared identity's record" "$first" "$(sed -n '3p' "$shared_entry")"
cp "$shared_entry" "$TEST_TMP/shared-record.expected"

: > "$log"
error=$(lifecycle "$second" sh "$WORKSPACE_HOME/lib/bootstrap.sh" 2>&1 >/dev/null)
assert_equal "second worktree with the same identity fails bootstrap" "1" "$?"
assert_true "bootstrap refusal names the other worktree" \
  sh -c 'printf "%s\n" "$1" | grep -Fq "already registered to another worktree: $2"' _ "$error" "$first"
assert_true "bootstrap refusal leaves the first worktree's record alone" cmp -s "$TEST_TMP/shared-record.expected" "$shared_entry"
assert_equal "refused bootstrap runs no setup or database commands" "" "$(cat "$log")"
assert_false "refused bootstrap writes no identity marker" [ -e "$second/.workspace" ]
assert_false "refused bootstrap releases the registry lock" [ -e "$git_root/.git/workspace/prune.lock" ]

: > "$log"
error=$(lifecycle "$second" sh "$WORKSPACE_HOME/lib/run.sh" 2>&1 >/dev/null)
assert_equal "second worktree with the same identity fails run" "1" "$?"
assert_true "run refusal names the other worktree" \
  sh -c 'printf "%s\n" "$1" | grep -Fq "already registered to another worktree: $2"' _ "$error" "$first"
assert_true "run refusal leaves the first worktree's record alone" cmp -s "$TEST_TMP/shared-record.expected" "$shared_entry"
assert_equal "refused run sweeps no ports and starts nothing" "" "$(cat "$log")"

# The owner may register again, from its path or another spelling of it.
lifecycle "$first" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_equal "the owning worktree still runs" "0" "$?"
ln -s "$first" "$TEST_TMP/first-link"
lifecycle "$TEST_TMP/first-link" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "the owning worktree bootstraps through a symlinked path" "0" "$?"
assert_equal "the owning worktree keeps its record" "$first" "$(sed -n '3p' "$shared_entry")"

# Once the owner is gone, its record no longer blocks the identity.
git -C "$git_root" worktree remove -f "$first"
lifecycle "$second" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "the identity is free once the other worktree is removed" "0" "$?"
assert_equal "the remaining worktree takes the record" "$second" "$(sed -n '3p' "$shared_entry")"

# A directory left at the owner's path that is no longer its worktree does not
# block the identity either.
git -C "$git_root" worktree remove -f "$second"
mkdir -p "$second"
reused=$(add_worktree "feature-implement-the-new-billing-system-part-3")
lifecycle "$reused" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "a leftover directory at the owner's path does not block the identity" "0" "$?"
assert_equal "the new worktree takes the record" "$reused" "$(sed -n '3p' "$shared_entry")"
git -C "$git_root" worktree remove -f "$reused"

# Characters sanitizing drops collapse names too: both of these become "wt".
accented=$(add_worktree "$(printf '\303\274-wt-\303\251')")
plain=$(add_worktree "wt")
cd "$accented"
resolve_workspace
sanitize_workspace_name
assert_equal "the accented worktree sanitizes to the plain name" "wt" "$WORKSPACE_NAME"
assert_true "the accented worktree registers" register_workspace "51800"
cd "$plain"
resolve_workspace
sanitize_workspace_name
assert_false "a worktree whose name only drops non-ASCII characters is refused" register_workspace "51810" 2>/dev/null
assert_equal "the refusal keeps the accented worktree's record" "$accented" "$(sed -n '3p' "$git_root/.git/workspace/registry/wt.record")"

cd "$TEST_DIR"
report "duplicate workspace identity"
