#!/bin/sh
# Commands that change things must not act on arguments they do not know.

. "$(dirname "$0")/test_helper.sh"

# A linked worktree whose Rails stub records every call.
worktree_app() {
  _app="$TEST_TMP/$1"
  mkdir -p "$_app/app/bin" "$_app/app/config"
  printf 'development:\n  database: app_development\n' > "$_app/app/config/database.yml"
  cat > "$_app/app/bin/rails" <<'SCRIPT'
#!/bin/sh
echo "$RAILS_ENV $*" >> "$WORKSPACE_TEST_RAILS_LOG"
case "$*" in
  runner*) echo workspace-suffix-checked ;;
esac
SCRIPT
  chmod +x "$_app/app/bin/rails"
  commit_git_repo "$_app/app"
  git -C "$_app/app" worktree add -q "$_app/wt" -b wt
  export WORKSPACE_TEST_RAILS_LOG="$_app/rails.log"
  (cd "$_app/wt" && WORKSPACE_PORT=51280 sh "$WORKSPACE_HOME/lib/bootstrap.sh" >/dev/null 2>&1)
  : > "$WORKSPACE_TEST_RAILS_LOG"
}

registered_count() {
  ls "$1/.git/workspace/registry" | wc -l | tr -d ' '
}

worktree_app args
app="$TEST_TMP/args"
assert_equal "bootstrap registers the test worktree" "1" "$(registered_count "$app/app")"

# archive

for bad_argument in --dry-run help extra; do
  output=$(cd "$app/wt" && WORKSPACE_PORT=51280 "$WORKSPACE_HOME/bin/workspace" archive "$bad_argument" 2>&1)
  assert_equal "archive $bad_argument fails" "1" "$?"
  case "$output" in
    *"does not take '$bad_argument'. Nothing was changed."*) names=yes ;;
    *) names=no ;;
  esac
  assert_equal "archive $bad_argument names the argument" "yes" "$names"
done
assert_equal "refused archives run no Rails commands" "" "$(cat "$WORKSPACE_TEST_RAILS_LOG")"
assert_equal "refused archives keep the registration" "1" "$(registered_count "$app/app")"

# prune

rm -rf "$app/wt"
for bad_arguments in --dry-run "--deferred --dry-run" "--quiet extra"; do
  # shellcheck disable=SC2086
  (cd "$app/app" && WORKSPACE_PORT=51280 "$WORKSPACE_HOME/bin/workspace" prune $bad_arguments >/dev/null 2>&1)
  assert_equal "prune $bad_arguments fails" "1" "$?"
done
assert_equal "refused prunes run no Rails commands" "" "$(cat "$WORKSPACE_TEST_RAILS_LOG")"
assert_equal "refused prunes keep the registration" "1" "$(registered_count "$app/app")"

# The documented forms still work.
(cd "$app/app" && "$WORKSPACE_HOME/bin/workspace" prune >/dev/null 2>&1)
assert_equal "prune still cleans up" "0" "$?"
assert_true "prune still drops databases" grep -q 'db:drop' "$WORKSPACE_TEST_RAILS_LOG"
assert_equal "prune still removes the registration" "0" "$(registered_count "$app/app")"

# bootstrap

worktree_app args-bootstrap
app="$TEST_TMP/args-bootstrap"
for bad_arguments in --dry-run "--once --dry-run"; do
  # shellcheck disable=SC2086
  output=$(cd "$app/wt" && rm -f .workspace && WORKSPACE_PORT=51280 "$WORKSPACE_HOME/bin/workspace" bootstrap $bad_arguments 2>&1)
  assert_equal "bootstrap $bad_arguments fails" "1" "$?"
  assert_false "bootstrap $bad_arguments writes no marker" [ -e "$app/wt/.workspace" ]
done
assert_equal "refused bootstraps run no Rails commands" "" "$(cat "$WORKSPACE_TEST_RAILS_LOG")"

(cd "$app/wt" && WORKSPACE_PORT=51280 "$WORKSPACE_HOME/bin/workspace" bootstrap --once >/dev/null 2>&1)
assert_equal "bootstrap --once still runs" "0" "$?"
assert_true "bootstrap --once still sets up a worktree missing its marker" [ -f "$app/wt/.workspace" ]

(cd "$app/wt" && WORKSPACE_PORT=51280 "$WORKSPACE_HOME/bin/workspace" archive >/dev/null 2>&1)
assert_equal "archive with no arguments still runs" "0" "$?"
assert_true "archive with no arguments still drops databases" grep -q 'db:drop' "$WORKSPACE_TEST_RAILS_LOG"
assert_equal "archive with no arguments removes the registration" "0" "$(registered_count "$app/app")"

report "lifecycle arguments"
