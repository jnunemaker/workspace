#!/bin/sh
# Tests for lib/install_skill.sh — symlinks the Claude Code skill.

cd "$(dirname "$0")"
. ./test_helper.sh

# Build a fake $WORKSPACE_HOME with the skill present.
FAKE_WS="$TEST_TMP/ws"
mkdir -p "$FAKE_WS/skills/workspace"
cp "$WORKSPACE_HOME/skills/workspace/SKILL.md" "$FAKE_WS/skills/workspace/SKILL.md"
cp "$WORKSPACE_HOME/lib/install_skill.sh" "$FAKE_WS/install_skill.sh"

# Each case gets its own fake $HOME so they don't bleed.
fresh_home() {
  local home="$TEST_TMP/home-$1"
  rm -rf "$home"
  mkdir -p "$home"
  [ "$2" = "with_claude" ] && mkdir -p "$home/.claude"
  [ "$2" = "with_codex" ] && mkdir -p "$home/.codex"
  [ "$2" = "with_both" ] && mkdir -p "$home/.claude" "$home/.codex"
  echo "$home"
}

run_installer() {
  HOME="$1" WORKSPACE_HOME="$FAKE_WS" \
    WORKSPACE_SKIP_CLAUDE_SKILL="${2:-0}" \
    WORKSPACE_SKIP_CODEX_SKILL="${3:-0}" \
    sh "$FAKE_WS/install_skill.sh" >/dev/null 2>&1
}

run_installer_with_codex_home() {
  HOME="$1" WORKSPACE_HOME="$FAKE_WS" CODEX_HOME="$2" \
    sh "$FAKE_WS/install_skill.sh" >/dev/null 2>&1
}

run_concurrent_installers() {
  local home="$1"
  local fake_bin="$TEST_TMP/concurrent-bin"
  local barrier="$TEST_TMP/concurrent-ln-barrier"
  local first_pid second_pid

  mkdir -p "$fake_bin" "$barrier"
  cat > "$fake_bin/ln" <<'SH'
#!/bin/sh
: > "$WORKSPACE_LN_BARRIER/$$"
if [ ! -d "$WORKSPACE_INSTALL_LOCK" ]; then
  while [ "$(find "$WORKSPACE_LN_BARRIER" -type f | wc -l | tr -d ' ')" -lt 2 ]; do
    sleep 0.01
  done
fi
exec /bin/ln "$@"
SH
  chmod +x "$fake_bin/ln"

  PATH="$fake_bin:$PATH" HOME="$home" WORKSPACE_HOME="$FAKE_WS" \
    WORKSPACE_LN_BARRIER="$barrier" \
    WORKSPACE_INSTALL_LOCK="$home/.claude/skills/.workspace-install.lock" \
    sh "$FAKE_WS/install_skill.sh" >/dev/null 2>&1 &
  first_pid=$!
  PATH="$fake_bin:$PATH" HOME="$home" WORKSPACE_HOME="$FAKE_WS" \
    WORKSPACE_LN_BARRIER="$barrier" \
    WORKSPACE_INSTALL_LOCK="$home/.claude/skills/.workspace-install.lock" \
    sh "$FAKE_WS/install_skill.sh" >/dev/null 2>&1 &
  second_pid=$!

  wait "$first_pid"
  first_status=$?
  wait "$second_pid"
  second_status=$?
}

# ── creates symlink when ~/.claude exists ───────────────────────

home=$(fresh_home creates with_claude)
run_installer "$home"

assert_true "symlink created at ~/.claude/skills/workspace" \
  [ -L "$home/.claude/skills/workspace" ]
assert_equal "symlink points at workspace skill dir" \
  "$FAKE_WS/skills/workspace" \
  "$(readlink "$home/.claude/skills/workspace")"

# ── idempotent: re-running leaves the symlink intact ────────────

run_installer "$home"
assert_true "symlink still present after re-run" \
  [ -L "$home/.claude/skills/workspace" ]
assert_equal "symlink target unchanged after re-run" \
  "$FAKE_WS/skills/workspace" \
  "$(readlink "$home/.claude/skills/workspace")"
assert_false "re-run does not create a nested workspace symlink" \
  [ -L "$FAKE_WS/skills/workspace/workspace" ]

# ── opt-out: WORKSPACE_SKIP_CLAUDE_SKILL=1 skips ────────────────

home=$(fresh_home optout with_claude)
run_installer "$home" 1

assert_false "no symlink when opt-out is set" \
  [ -e "$home/.claude/skills/workspace" ]

# ── no ~/.claude: silent no-op ──────────────────────────────────

home=$(fresh_home noclaude)
run_installer "$home"

assert_false "no symlink when ~/.claude is absent" \
  [ -e "$home/.claude/skills/workspace" ]
assert_false "~/.claude not created" \
  [ -d "$home/.claude" ]

# ── Codex installs independently without changing Claude behavior ─

home=$(fresh_home codex with_codex)
run_installer "$home"
assert_true "symlink created at ~/.codex/skills/workspace" \
  [ -L "$home/.codex/skills/workspace" ]
assert_equal "Codex symlink points at workspace skill dir" \
  "$FAKE_WS/skills/workspace" \
  "$(readlink "$home/.codex/skills/workspace")"
assert_false "Codex-only install does not create ~/.claude" [ -d "$home/.claude" ]

run_installer "$home"
assert_equal "Codex re-run leaves the symlink target unchanged" \
  "$FAKE_WS/skills/workspace" \
  "$(readlink "$home/.codex/skills/workspace")"
assert_false "Codex re-run does not create a nested workspace symlink" \
  [ -L "$FAKE_WS/skills/workspace/workspace" ]

home=$(fresh_home custom-codex-home)
custom_codex_home="$TEST_TMP/custom-codex-home"
mkdir -p "$custom_codex_home"
run_installer_with_codex_home "$home" "$custom_codex_home"
assert_equal "custom CODEX_HOME receives the workspace skill" \
  "$FAKE_WS/skills/workspace" \
  "$(readlink "$custom_codex_home/skills/workspace")"
assert_false "custom CODEX_HOME does not create the default directory" [ -d "$home/.codex" ]

home=$(fresh_home codex-optout with_both)
run_installer "$home" 0 1
assert_true "Codex opt-out leaves Claude install enabled" [ -L "$home/.claude/skills/workspace" ]
assert_false "Codex opt-out skips Codex symlink" [ -e "$home/.codex/skills/workspace" ]

home=$(fresh_home codex-conflict with_codex)
mkdir -p "$home/.codex/skills/workspace"
echo "user codex content" > "$home/.codex/skills/workspace/SKILL.md"
run_installer "$home"
assert_false "Codex install preserves an existing real directory" [ -L "$home/.codex/skills/workspace" ]
assert_true "existing Codex skill content is preserved" grep -q "user codex content" "$home/.codex/skills/workspace/SKILL.md"
assert_false "Codex conflict does not create a nested workspace symlink" \
  [ -L "$home/.codex/skills/workspace/workspace" ]

# ── concurrent installers cannot follow the winning directory symlink ──

home=$(fresh_home concurrent with_claude)
run_concurrent_installers "$home"

assert_equal "first concurrent installer succeeds" "0" "$first_status"
assert_equal "second concurrent installer succeeds" "0" "$second_status"
assert_equal "concurrent install leaves the intended symlink" \
  "$FAKE_WS/skills/workspace" \
  "$(readlink "$home/.claude/skills/workspace")"
assert_false "concurrent install does not create a nested workspace symlink" \
  [ -L "$FAKE_WS/skills/workspace/workspace" ]

# ── conflict: existing real directory at target ─────────────────

home=$(fresh_home conflict-dir with_claude)
mkdir -p "$home/.claude/skills/workspace"
echo "user content" > "$home/.claude/skills/workspace/SKILL.md"
run_installer "$home"

assert_false "doesn't replace existing real directory with symlink" \
  [ -L "$home/.claude/skills/workspace" ]
assert_true "existing user content preserved" \
  grep -q "user content" "$home/.claude/skills/workspace/SKILL.md"
assert_false "directory conflict does not create a nested workspace symlink" \
  [ -L "$home/.claude/skills/workspace/workspace" ]

# ── conflict: existing symlink pointing elsewhere ───────────────

home=$(fresh_home conflict-link with_claude)
mkdir -p "$home/.claude/skills" "$TEST_TMP/other"
ln -s "$TEST_TMP/other" "$home/.claude/skills/workspace"
run_installer "$home"

assert_equal "leaves foreign symlink target alone" \
  "$TEST_TMP/other" \
  "$(readlink "$home/.claude/skills/workspace")"

report "install_skill.sh"
