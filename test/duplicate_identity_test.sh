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
assert_equal "the record holds the owner's worktree token" \
  "$(cat "$(git -C "$first" rev-parse --absolute-git-dir)/workspace-owner-token")" "$(sed -n '5p' "$shared_entry")"
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

# Archive from the refused worktree would tear down the owner's resources.
: > "$log"
error=$(lifecycle "$second" sh "$WORKSPACE_HOME/lib/archive.sh" 2>&1 >/dev/null)
assert_equal "second worktree with the same identity fails archive" "1" "$?"
assert_true "archive refusal names the other worktree" \
  sh -c 'printf "%s\n" "$1" | grep -Fq "already registered to another worktree: $2"' _ "$error" "$first"
assert_true "archive refusal leaves the first worktree's record alone" cmp -s "$TEST_TMP/shared-record.expected" "$shared_entry"
assert_equal "refused archive sweeps no ports and drops no databases" "" "$(cat "$log")"

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

# A moved owner keeps its identity, its databases, and its Git worktree
# directory, but not its path. It still owns the record.
owner=$(add_worktree "feature-implement-the-new-billing-system-part-5")
lifecycle "$owner" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "an owner bootstraps before moving" "0" "$?"
git -C "$git_root" worktree move "$owner" "$TEST_TMP/moved-owner"
moved=$(cd "$TEST_TMP/moved-owner" && pwd -P)
cp "$shared_entry" "$TEST_TMP/moved-record.expected"
collider=$(add_worktree "feature-implement-the-new-billing-system-part-6")
: > "$log"
error=$(lifecycle "$collider" sh "$WORKSPACE_HOME/lib/bootstrap.sh" 2>&1 >/dev/null)
assert_equal "a colliding worktree is refused while the owner lives at a new path" "1" "$?"
assert_true "the refusal names the owner's new path" \
  sh -c 'printf "%s\n" "$1" | grep -Fq "already registered to another worktree: $2"' _ "$error" "$moved"
assert_true "the refusal leaves the moved owner's record alone" cmp -s "$TEST_TMP/moved-record.expected" "$shared_entry"
assert_equal "the refused collider runs no setup or database commands" "" "$(cat "$log")"
lifecycle "$moved" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_equal "the moved owner still runs" "0" "$?"
assert_equal "the moved owner's record follows it" "$moved" "$(sed -n '3p' "$shared_entry")"

# Once the owner is removed, a worktree with another identity at its old path
# does not keep the name blocked.
git -C "$git_root" worktree remove -f "$moved"
git -C "$git_root" worktree add -q --detach "$moved"
printf 'other-identity\n' > "$moved/.workspace"
lifecycle "$collider" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "another identity at the removed owner's path does not block the name" "0" "$?"
assert_equal "the collider takes the record" "$collider" "$(sed -n '3p' "$shared_entry")"
git -C "$git_root" worktree remove -f "$moved"

# A four-line record from an older version still blocks by its path, and the
# owner's next registration adds its Git worktree directory.
head -n 4 "$shared_entry" > "$shared_entry.old" && mv "$shared_entry.old" "$shared_entry"
latecomer=$(add_worktree "feature-implement-the-new-billing-system-part-7")
lifecycle "$latecomer" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "an older record still refuses a collider while its path is live" "1" "$?"
lifecycle "$collider" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_equal "the owner of an older record still runs" "0" "$?"
assert_equal "the owner's run upgrades the record" \
  "$(cat "$(git -C "$collider" rev-parse --absolute-git-dir)/workspace-owner-token")" "$(sed -n '5p' "$shared_entry")"

# An owner that later registers under another identity keeps the first one
# until it archives it.
printf 'collider-renamed\n' > "$collider/.workspace"
lifecycle "$collider" sh "$WORKSPACE_HOME/lib/run.sh" >/dev/null 2>&1
assert_equal "the owner runs under its new identity" "0" "$?"
lifecycle "$latecomer" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "a renamed owner still holds its earlier identity" "1" "$?"
git -C "$git_root" worktree remove -f "$latecomer"

# A checkout of another repository at the owner's path is not the owner, even
# while Git still has the owner's worktree directory.
rm -rf "$collider"
other_root="$TEST_TMP/other-root"
mkdir -p "$other_root"
printf 'other\n' > "$other_root/README.md"
commit_git_repo "$other_root"
git -C "$other_root" worktree add -q --detach "$collider"
latecomer=$(add_worktree "feature-implement-the-new-billing-system-part-8")
lifecycle "$latecomer" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "another repository's checkout at the owner's path does not block the name" "0" "$?"
git -C "$other_root" worktree remove -f "$collider"
git -C "$git_root" worktree prune

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

# The registry moves with the main checkout. Once Git repairs the worktree
# links, the owner is still found.
cd "$TEST_DIR"
mv "$git_root" "$git_root-moved"
git_root="$git_root-moved"
git -C "$git_root" worktree repair >/dev/null 2>&1
latest=$(add_worktree "feature-implement-the-new-billing-system-part-9")
lifecycle "$latest" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1
assert_equal "the owner is still found after the main checkout moves" "1" "$?"

cd "$TEST_DIR"
report "duplicate workspace identity"
