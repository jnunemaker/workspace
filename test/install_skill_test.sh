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
  echo "$home"
}

run_installer() {
  HOME="$1" WORKSPACE_HOME="$FAKE_WS" \
    WORKSPACE_SKIP_CLAUDE_SKILL="${2:-0}" \
    sh "$FAKE_WS/install_skill.sh" >/dev/null 2>&1
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

# ── conflict: existing real directory at target ─────────────────

home=$(fresh_home conflict-dir with_claude)
mkdir -p "$home/.claude/skills/workspace"
echo "user content" > "$home/.claude/skills/workspace/SKILL.md"
run_installer "$home"

assert_false "doesn't replace existing real directory with symlink" \
  [ -L "$home/.claude/skills/workspace" ]
assert_true "existing user content preserved" \
  grep -q "user content" "$home/.claude/skills/workspace/SKILL.md"

# ── conflict: existing symlink pointing elsewhere ───────────────

home=$(fresh_home conflict-link with_claude)
mkdir -p "$home/.claude/skills" "$TEST_TMP/other"
ln -s "$TEST_TMP/other" "$home/.claude/skills/workspace"
run_installer "$home"

assert_equal "leaves foreign symlink target alone" \
  "$TEST_TMP/other" \
  "$(readlink "$home/.claude/skills/workspace")"

report "install_skill.sh"
