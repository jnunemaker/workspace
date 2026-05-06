#!/bin/sh
# Link the Claude Code skill into ~/.claude/skills/ if Claude Code is present.
# Idempotent — safe to call from install and update.
# Opt out with WORKSPACE_SKIP_CLAUDE_SKILL=1.

WORKSPACE_HOME="${WORKSPACE_HOME:-$HOME/.workspace}"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
SKILL_SRC="$WORKSPACE_HOME/skills/workspace"
SKILL_LINK="$CLAUDE_SKILLS_DIR/workspace"

[ "${WORKSPACE_SKIP_CLAUDE_SKILL:-0}" = "1" ] && exit 0
[ ! -d "$HOME/.claude" ] && exit 0
[ ! -d "$SKILL_SRC" ] && exit 0

mkdir -p "$CLAUDE_SKILLS_DIR"

if [ -L "$SKILL_LINK" ] || [ -e "$SKILL_LINK" ]; then
  if [ "$(readlink "$SKILL_LINK" 2>/dev/null)" = "$SKILL_SRC" ]; then
    exit 0
  fi
  echo "  Skipping Claude skill install: $SKILL_LINK exists and is not our symlink" >&2
  exit 0
fi

ln -s "$SKILL_SRC" "$SKILL_LINK"
echo "  Linked Claude skill to $SKILL_LINK"
