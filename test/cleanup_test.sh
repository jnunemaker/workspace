#!/bin/sh
# Test cleanup with fake socket inspection, signals and application commands.
cd "$(dirname "$0")" || exit 1
. ./test_helper.sh
[ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ] || exit 1
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_PORT
unset SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME SUPERSET_PORT WORKSPACE_PORT
mkdir -p "$TEST_TMP/app/bin" "$TEST_TMP/app/config" "$TEST_TMP/root" "$TEST_TMP/tools" || exit 1
export CLEANUP_CLOCK="$TEST_TMP/clock" CLEANUP_CALLS="$TEST_TMP/calls" CLEANUP_SIGNALS="$TEST_TMP/signals" CLEANUP_ACTIONS="$TEST_TMP/actions"
export PATH="$TEST_TMP/tools:$PATH"
cat > "$TEST_TMP/tools/date" <<'SCRIPT'
#!/bin/sh
if [ "$CLEANUP_SCENARIO" = probe-timeout ]; then
  clock=$(cat "$CLEANUP_CLOCK"); printf '%s' "$((clock+1))" > "$CLEANUP_CLOCK"
fi
cat "$CLEANUP_CLOCK"
SCRIPT
cat > "$TEST_TMP/tools/sleep" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
cat > "$TEST_TMP/tools/lsof" <<'SCRIPT'
#!/bin/sh
calls=$(cat "$CLEANUP_CALLS"); calls=$((calls+1)); printf '%s' "$calls" > "$CLEANUP_CALLS"
printf '%s' "$calls" > "$CLEANUP_CLOCK"
case "$CLEANUP_SCENARIO" in
  error) echo 'inspection unavailable' >&2; exit 1 ;;
  empty) exit 1 ;;
  probe-timeout) exec /bin/sleep 30 ;;
  unavailable) exit 127 ;;
  warning) echo 'partial visibility' >&2 ;;
  inspection-budget) printf 5 > "$CLEANUP_CLOCK" ;;
  delayed) [ "$calls" -lt 3 ] || exit 1 ;;
  race) [ "$calls" -lt 2 ] || exit 1 ;;
esac
case "$*" in
  *-F*) ;;
  *) printf '12345\n'; exit 0 ;;
esac
if [ "$CLEANUP_SCENARIO" = malformed ]; then printf 'garbage\n'; exit 0; fi
# Include an established TCP client whose REMOTE port is in the block.
cat <<'DATA'
p54321
cclient
u1000
Ldeveloper
f3
PTCP
n127.0.0.1:60100->127.0.0.1:57690
TST=ESTABLISHED
f6
PUDP
n127.0.0.1:60101->127.0.0.1:57690
DATA
[ "$CLEANUP_SCENARIO" != client ] || exit 0
if [ "$CLEANUP_SCENARIO" = replacement ] && [ "$calls" -gt 1 ]; then
  printf 'p23456\ncreplacement\nu1000\nf4\nPTCP\nn127.0.0.1:57690\nTST=LISTEN\n'
  exit 0
fi
cat <<'DATA'
p12345
cruby
u1000
Ldeveloper
f4
PTCP
n127.0.0.1:57690
TST=LISTEN
f5
PUDP
n[::1]:57691
DATA
SCRIPT
chmod +x "$TEST_TMP/tools/"*
cd "$TEST_TMP/app" || exit 1
printf 'development:\n  database: app_development\ntest:\n  database: app_test\n' > config/database.yml
for executable in foreman rails workspace-run-hook workspace-archive-hook; do
  cat > "bin/$executable" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$CLEANUP_ACTIONS"
SCRIPT
  chmod +x "bin/$executable"
done
export CONDUCTOR_ROOT_PATH="$TEST_TMP/root" CONDUCTOR_WORKSPACE_NAME=cleanup CONDUCTOR_PORT=57690
reset_case() {
  printf 0 > "$CLEANUP_CLOCK"; printf 0 > "$CLEANUP_CALLS"
  : > "$CLEANUP_ACTIONS"; : > "$CLEANUP_SIGNALS"
  CLEANUP_SCENARIO="$1"; export CLEANUP_SCENARIO
}
run_command() {
  # Override only application signals. The helper uses command kill to poll
  # its own lsof child; those are real test-owned processes, never services.
  "${CLEANUP_TEST_SHELL:-sh}" -c 'kill() { printf "%s\n" "$*" >> "$CLEANUP_SIGNALS"; return "${CLEANUP_SIGNAL_STATUS:-0}"; }; . "$1"' "$WORKSPACE_HOME/lib/$1.sh" "$WORKSPACE_HOME/lib/$1.sh"
}
reset_case persistent
assert_false "run fails if sockets remain occupied" run_command run > "$TEST_TMP/run.out" 2>&1
assert_false "failed run never starts Foreman or startup hook" test -s "$CLEANUP_ACTIONS"
assert_true "failure identifies remaining port" grep -q 57690 "$TEST_TMP/run.out"
assert_true "failure identifies process and user" grep -q 'ruby.*developer' "$TEST_TMP/run.out"
assert_false "clients are not selected for termination" grep -q 54321 "$CLEANUP_SIGNALS"
assert_equal "one TERM per process across multiple sockets" 1 "$(wc -l < "$CLEANUP_SIGNALS" | tr -d ' ')"
reset_case persistent
assert_false "archive fails if sockets remain occupied" run_command archive > "$TEST_TMP/archive.out" 2>&1
assert_false "failed archive never drops databases" grep -q db:drop "$CLEANUP_ACTIONS"
assert_false "failed archive does not claim cleared ports" grep -q 'Ports cleared' "$TEST_TMP/archive.out"
for scenario in empty client delayed race; do
  reset_case "$scenario"
  assert_true "$scenario cleanup allows startup" run_command run > "$TEST_TMP/$scenario.out" 2>&1
  assert_true "$scenario starts Foreman" grep -q foreman "$CLEANUP_ACTIONS"
done
for scenario in error malformed warning unavailable probe-timeout inspection-budget; do
  reset_case "$scenario"
  assert_false "$scenario inspection aborts startup" run_command run > "$TEST_TMP/$scenario.out" 2>&1
  assert_false "$scenario inspection sends no application signal" test -s "$CLEANUP_SIGNALS"
  assert_false "$scenario inspection starts no application work" test -s "$CLEANUP_ACTIONS"
done
assert_true "partial inspection retains available process details" grep -q '12345.*ruby.*developer' "$TEST_TMP/warning.out"
reset_case replacement
assert_false "replacement listener prevents success" run_command run > "$TEST_TMP/replacement.out" 2>&1
assert_true "failure shows current replacement PID" grep -q 23456 "$TEST_TMP/replacement.out"
assert_false "replacement is not signaled" grep -q 23456 "$CLEANUP_SIGNALS"
assert_true "local UDP socket appears in diagnostic" grep -q 'UDP.*\[::1\]:57691' "$TEST_TMP/run.out"
assert_true "remaining socket state is reported" grep -q LISTEN "$TEST_TMP/run.out"
reset_case race
CLEANUP_SIGNAL_STATUS=1; export CLEANUP_SIGNAL_STATUS
assert_true "failed signal followed by released ports succeeds" run_command run > "$TEST_TMP/signal-race.out" 2>&1
reset_case persistent
assert_false "failed signal with occupied port stops" run_command run > "$TEST_TMP/signal-failed.out" 2>&1
unset CLEANUP_SIGNAL_STATUS

# Retain recovery registration and release the lock when archive fails.
git init -q "$TEST_TMP/git-root" || exit 1
git -C "$TEST_TMP/git-root" -c user.name=Test -c user.email=test@example.com commit --no-gpg-sign -qm initial --allow-empty || exit 1
git -C "$TEST_TMP/git-root" worktree add -q --detach "$TEST_TMP/linked" || exit 1
cp -R bin config "$TEST_TMP/linked/" || exit 1
cd "$TEST_TMP/linked" || exit 1
unset CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME CONDUCTOR_PORT
WORKSPACE_PORT=57690; export WORKSPACE_PORT
reset_case empty
assert_true "Git run publishes registration" run_command run > "$TEST_TMP/git-run.out" 2>&1
record="$TEST_TMP/git-root/.git/workspace/registry/linked.record"
assert_true "Git registration exists" test -f "$record"
reset_case persistent
assert_false "Git archive reports failed cleanup" run_command archive > "$TEST_TMP/git-archive.out" 2>&1
assert_true "failed archive retains registration" test -f "$record"
assert_false "failed archive releases registry lock" test -e "$TEST_TMP/git-root/.git/workspace/prune.lock"
assert_false "failed Git archive never drops databases" grep -q db:drop "$CLEANUP_ACTIONS"
report "verified port cleanup"
