#!/bin/sh
# Manager environment belongs to one checkout, not its child agent shells.
cd "$(dirname "$0")" || exit 1
. ./test_helper.sh
. "$WORKSPACE_HOME/lib/registry.sh"
[ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ] || exit 1

unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH SUPERCONDUCTOR_PORT
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME SUPERSET_WORKSPACE_PATH SUPERSET_PORT
unset CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME CONDUCTOR_WORKSPACE_PATH CONDUCTOR_PORT WORKSPACE_PORT

root="$TEST_TMP/root"
owner="$TEST_TMP/physical-manager-checkout"
child="$TEST_TMP/child"
git init -q "$root" || exit 1
git -C "$root" -c user.name=Test -c user.email=test@example.com commit --no-gpg-sign -qm initial --allow-empty || exit 1
git -C "$root" worktree add -q --detach "$owner" || exit 1
git -C "$root" worktree add -q --detach "$child" || exit 1
root=$(cd "$root" && pwd -P) || exit 1
owner=$(cd "$owner" && pwd -P) || exit 1
child=$(cd "$child" && pwd -P) || exit 1
ln -s "$owner" "$TEST_TMP/manager-display-name" || exit 1
manager_root="$TEST_TMP/manager-root"
mkdir -p "$manager_root" || exit 1

for family in SUPERCONDUCTOR SUPERSET CONDUCTOR; do
  (
    PASS=0 FAIL=0 ERRORS=""
    cd "$child"
    export "${family}_ROOT_PATH=$manager_root" "${family}_WORKSPACE_NAME=manager-display-name"
    export "${family}_WORKSPACE_PATH=$TEST_TMP/manager-display-name" "${family}_PORT=41000"
    resolve_workspace
    sanitize_workspace_name
    assert_equal "$family child uses Git" git "$WORKSPACE_PROVIDER"
    assert_equal "$family child uses its name" child "$WORKSPACE_NAME"
    assert_equal "$family child uses Git root" "$root" "$WORKSPACE_ROOT_PATH"
    assert_false "$family child rejects inherited port" test "$(resolve_workspace_port 3000)" = 41000
    printf child-pinned > .workspace
    resolve_workspace_identity >/dev/null
    assert_equal "$family child retains Workspace marker" child-pinned "$WORKSPACE_NAME"
    printf child-legacy > .conductor-workspace
    resolve_workspace_identity >/dev/null
    assert_equal "$family child retains marker identity" child-legacy "$WORKSPACE_NAME"
    rm .workspace .conductor-workspace

    # A symlink and a display name unrelated to the physical basename are
    # ordinary manager inputs, not evidence that this is a child checkout.
    cd "$owner"
    export "${family}_ROOT_PATH=$manager_root" "${family}_WORKSPACE_NAME=manager-display-name"
    export "${family}_WORKSPACE_PATH=$TEST_TMP/manager-display-name" "${family}_PORT=41000"
    resolve_workspace
    sanitize_workspace_name
    assert_equal "$family symlink owner retains provider" "$(printf '%s' "$family" | tr '[:upper:]' '[:lower:]')" "$WORKSPACE_PROVIDER"
    assert_equal "$family symlink owner retains display identity" manager-display-name "$WORKSPACE_NAME"
    assert_equal "$family symlink owner retains manager root" "$manager_root" "$WORKSPACE_ROOT_PATH"
    if [ "$family" = SUPERSET ]; then
      # SUPERSET_PORT is Superset's notification port, never a workspace port.
      assert_false "$family symlink owner ignores notification port" test "$(resolve_workspace_port 3000)" = 41000
    else
      assert_equal "$family symlink owner retains manager port" 41000 "$(resolve_workspace_port 3000)"
    fi

    unset "${family}_ROOT_PATH" "${family}_WORKSPACE_NAME"
    resolve_workspace
    assert_equal "$family own port-only keeps Git isolation" git "$WORKSPACE_PROVIDER"
    assert_equal "$family own port-only keeps Git name" physical-manager-checkout "$WORKSPACE_NAME"
    if [ "$family" = SUPERSET ]; then
      assert_false "$family own port-only ignores notification port" test "$(resolve_workspace_port 3000)" = 41000
    else
      assert_equal "$family own port-only accepts verified port" 41000 "$(resolve_workspace_port 3000)"
    fi
    cd "$child"
    resolve_workspace
    assert_equal "$family foreign port-only keeps Git isolation" git "$WORKSPACE_PROVIDER"
    assert_false "$family foreign port-only rejects manager port" test "$(resolve_workspace_port 3000)" = 41000

    fields="ROOT_PATH WORKSPACE_NAME PORT"
    if [ "$family" = SUPERSET ]; then
      fields="ROOT_PATH WORKSPACE_NAME"
      unset SUPERSET_WORKSPACE_PATH
      export SUPERSET_PORT=41000
      assert_true "$family notification port alone is not manager input" resolve_workspace
      assert_equal "$family notification port is left for Superset" 41000 "${SUPERSET_PORT:-}"
      unset SUPERSET_PORT
    fi
    for field in $fields; do
      export "${family}_${field}=41000"
      unset "${family}_WORKSPACE_PATH"
      assert_false "$family $field without owner fails" resolve_workspace >"$TEST_TMP/error" 2>&1
      assert_true "$family owner error identifies recovery" grep -q 'Relaunch from the manager or use a clean shell' "$TEST_TMP/error"
      export "${family}_WORKSPACE_PATH=$TEST_TMP/nonexistent"
      assert_false "$family nonexistent owner fails" resolve_workspace >/dev/null 2>&1
      unset "${family}_${field}" "${family}_WORKSPACE_PATH"
    done
    report "$family ownership"
  )
  assert_equal "$family ownership cases pass" 0 "$?"
done

# Selection stays within one verified family. A higher-priority inherited
# family is discarded before considering a manager that owns this checkout.
(
  PASS=0 FAIL=0 ERRORS=""
  cd "$child"
  SUPERCONDUCTOR_ROOT_PATH=/wrong/root
  SUPERCONDUCTOR_WORKSPACE_NAME=wrong-name
  SUPERCONDUCTOR_WORKSPACE_PATH="$owner"
  SUPERCONDUCTOR_PORT=41000
  SUPERSET_WORKSPACE_PATH="$child"
  SUPERSET_WORKSPACE_NAME=child-manager
  CONDUCTOR_WORKSPACE_PATH="$child"
  CONDUCTOR_ROOT_PATH=/other/root
  CONDUCTOR_PORT=42000
  resolve_workspace
  sanitize_workspace_name
  assert_equal "matching lower-priority manager is selected" superset "$WORKSPACE_PROVIDER"
  assert_equal "selected family supplies identity" child-manager "$WORKSPACE_NAME"
  assert_equal "selected family does not borrow lower-priority root" "" "$WORKSPACE_ROOT_PATH"
  assert_false "selected family does not borrow another family port" test "$(resolve_workspace_port 3000)" = 42000
  report "mixed manager ownership"
)
assert_equal "mixed manager cases pass" 0 "$?"

# Exercise real lifecycle boundaries with harmless project executables. Every
# possible database/process action is a logger inside this test's temp tree.
fake_bin="$TEST_TMP/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/lsof" <<'SCRIPT'
#!/bin/sh
printf 'sweep:%s\n' "$*" >> "$OWNERSHIP_LOG"
exit 1
SCRIPT
chmod +x "$fake_bin/lsof"
PATH="$fake_bin:$PATH"
export PATH
for checkout in "$owner" "$child"; do
  mkdir -p "$checkout/bin" "$checkout/config"
  printf ':\n' > "$checkout/bin/workspace-environment-hook"
  printf 'development:\n  database: app_development\ntest:\n  database: app_test\n' > "$checkout/config/database.yml"
  for executable in setup rails foreman workspace-database-hook workspace-archive-hook; do
    cat > "$checkout/bin/$executable" <<'SCRIPT'
#!/bin/sh
printf '%s:%s:%s:%s:%s:%s\n' "${0##*/}" "$WORKSPACE_PROVIDER" "$WORKSPACE_NAME" "$WORKSPACE_ROOT_PATH" "$WORKSPACE_DB_SUFFIX" "$PORT $*" >> "$OWNERSHIP_LOG"
SCRIPT
    chmod +x "$checkout/bin/$executable"
  done
done
OWNERSHIP_LOG="$TEST_TMP/lifecycle.log"
export OWNERSHIP_LOG
export CONDUCTOR_WORKSPACE_PATH="$TEST_TMP/manager-display-name"
export CONDUCTOR_ROOT_PATH="$manager_root" CONDUCTOR_WORKSPACE_NAME=manager-display-name CONDUCTOR_PORT=41000

cd "$owner"
assert_true "symlink-owned manager bootstrap succeeds" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >"$TEST_TMP/bootstrap.out" 2>&1
assert_equal "manager bootstrap pins display identity, not physical basename" manager-display-name "$(cat .workspace)"
assert_true "database hook receives manager root" grep -Fq "workspace-database-hook:conductor:manager-display-name:$manager_root:_manager-display-name:" "$OWNERSHIP_LOG"
assert_false "manager bootstrap creates no Git registration" test -d "$root/.git/workspace/registry"
assert_true "managed run succeeds" sh "$WORKSPACE_HOME/lib/run.sh" >"$TEST_TMP/run.out" 2>&1
assert_true "managed run uses manager port and suffix" grep -Fq "foreman:conductor:manager-display-name:$manager_root:_manager-display-name:41000 " "$OWNERSHIP_LOG"
assert_true "managed archive succeeds" sh "$WORKSPACE_HOME/lib/archive.sh" >"$TEST_TMP/archive.out" 2>&1
assert_true "managed archive keeps manager suffix" grep -Fq "rails:conductor:manager-display-name:$manager_root:_manager-display-name: db:drop" "$OWNERSHIP_LOG"

cd "$child"
: > "$OWNERSHIP_LOG"
# Attempt reintroduction through both project sourcing boundaries. Neither
# should change identity nor leak rejected manager values to child processes.
cat > .env <<EOF
CONDUCTOR_ROOT_PATH='$manager_root'
CONDUCTOR_WORKSPACE_NAME=manager-display-name
CONDUCTOR_WORKSPACE_PATH='$owner'
CONDUCTOR_PORT=41000
EOF
cat > bin/workspace-environment-hook <<'SCRIPT'
export CONDUCTOR_ROOT_PATH=/wrong/root CONDUCTOR_WORKSPACE_NAME=wrong-name
export CONDUCTOR_WORKSPACE_PATH=/wrong/owner CONDUCTOR_PORT=41000
SCRIPT
cat >> bin/foreman <<'SCRIPT'
printf 'raw-manager:%s:%s:%s:%s\n' "$CONDUCTOR_ROOT_PATH" "$CONDUCTOR_WORKSPACE_NAME" "$CONDUCTOR_WORKSPACE_PATH" "$CONDUCTOR_PORT" >> "$OWNERSHIP_LOG"
SCRIPT
printf child-pinned > .workspace
assert_true "inherited manager child bootstrap succeeds" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >"$TEST_TMP/child-bootstrap.out" 2>&1
record="$root/.git/workspace/registry/child-pinned.record"
assert_true "child bootstrap registers its own identity" test -f "$record"
assert_equal "child registration records Git root" "$root" "$(sed -n '2p' "$record")"
assert_equal "child registration records child checkout" "$child" "$(sed -n '3p' "$record")"
child_port=$(sed -n '4p' "$record")
assert_false "child reservation rejects inherited manager port" test "$child_port" = 41000
assert_true "child database hook receives Git root" grep -Fq "workspace-database-hook:git:child-pinned:$root:_child-pinned:" "$OWNERSHIP_LOG"
assert_true "child run succeeds" sh "$WORKSPACE_HOME/lib/run.sh" >"$TEST_TMP/child-run.out" 2>&1
assert_true "child run uses registered port and marker suffix" grep -Fq "foreman:git:child-pinned:$root:_child-pinned:$child_port " "$OWNERSHIP_LOG"
assert_true "dotenv and environment hook cannot resurrect rejected family" grep -qx 'raw-manager::::' "$OWNERSHIP_LOG"
assert_true "child archive succeeds" sh "$WORKSPACE_HOME/lib/archive.sh" >"$TEST_TMP/child-archive.out" 2>&1
assert_false "child archive releases registration" test -f "$record"
assert_true "child archive drops only child suffix" grep -Fq "rails:git:child-pinned:$root:_child-pinned: db:drop" "$OWNERSHIP_LOG"
assert_false "child lifecycle never sweeps parent port" grep -q 'sweep:-ti :4100' "$OWNERSHIP_LOG"

# Missing ownership must stop before hooks, setup, registry cleanup, or drops,
# regardless of stable markers. An unusable path is not a mismatch fallback.
for command in bootstrap run archive info prune; do
  for owner_path in "" "$TEST_TMP/missing" "$child/.workspace"; do
    : > "$OWNERSHIP_LOG"
    assert_false "$command rejects unusable ownership" env CONDUCTOR_WORKSPACE_PATH="$owner_path" sh "$WORKSPACE_HOME/lib/$command.sh" >"$TEST_TMP/invalid.out" 2>&1
    assert_true "$command explains ownership failure" grep -q CONDUCTOR_WORKSPACE_PATH "$TEST_TMP/invalid.out"
    assert_false "$command performs no lifecycle action" test -s "$OWNERSHIP_LOG"
  done
done

mkdir -p "$TEST_TMP/non-git"
cd "$TEST_TMP/non-git"
assert_false "manager inputs outside Git fail ownership verification" env CONDUCTOR_WORKSPACE_PATH="$TEST_TMP/non-git" sh "$WORKSPACE_HOME/lib/bootstrap.sh" >"$TEST_TMP/non-git.out" 2>&1
assert_true "non-Git failure explains top-level verification" grep -q 'current Git top-level' "$TEST_TMP/non-git.out"

report "ownership"
