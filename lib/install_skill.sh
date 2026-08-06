#!/bin/sh
# Link the workspace skill into Claude Code and Codex when they are present.
# Idempotent — safe to call from install and update.
# Opt out independently with WORKSPACE_SKIP_CLAUDE_SKILL=1 or
# WORKSPACE_SKIP_CODEX_SKILL=1.

WORKSPACE_HOME="${WORKSPACE_HOME:-$HOME/.workspace}"
SKILL_SRC="$WORKSPACE_HOME/skills/workspace"

[ ! -d "$SKILL_SRC" ] && exit 0

install_workspace_skill() {
  _skill_product="$1"
  _skill_home="$2"
  _skill_opt_out="$3"

  [ "$_skill_opt_out" = "1" ] && return 0
  [ -d "$_skill_home" ] || return 0

  _skills_dir="$_skill_home/skills"
  _skill_link="$_skills_dir/workspace"
  _skill_lock="$_skills_dir/.workspace-install.lock"
  mkdir -p "$_skills_dir"

  if [ -L "$_skill_link" ] || [ -e "$_skill_link" ]; then
    if [ "$(readlink "$_skill_link" 2>/dev/null)" = "$SKILL_SRC" ]; then
      return 0
    fi
    echo "  Skipping $_skill_product skill install: $_skill_link exists and is not our symlink" >&2
    return 0
  fi

  _skill_lock_attempts=0
  while ! mkdir "$_skill_lock" 2>/dev/null; do
    if [ -L "$_skill_link" ] || [ -e "$_skill_link" ]; then
      if [ "$(readlink "$_skill_link" 2>/dev/null)" = "$SKILL_SRC" ]; then
        return 0
      fi
      echo "  Skipping $_skill_product skill install: $_skill_link exists and is not our symlink" >&2
      return 0
    fi

    _skill_lock_attempts=$((_skill_lock_attempts + 1))
    if [ "$_skill_lock_attempts" -ge 10 ]; then
      echo "  Could not lock $_skill_product skill install at $_skill_lock" >&2
      return 1
    fi
    sleep 1
  done

  trap 'rmdir "$_skill_lock" 2>/dev/null' EXIT
  trap 'rmdir "$_skill_lock" 2>/dev/null; exit 1' HUP INT TERM
  _skill_result=0

  # Recheck while holding the lock: another installer may have completed while
  # this process was waiting. The lock also prevents ln from following a
  # concurrently-created directory symlink and nesting a link in SKILL_SRC.
  if [ "$(readlink "$_skill_link" 2>/dev/null)" = "$SKILL_SRC" ]; then
    :
  elif [ -L "$_skill_link" ] || [ -e "$_skill_link" ]; then
    echo "  Skipping $_skill_product skill install: $_skill_link exists and is not our symlink" >&2
  elif ln -s "$SKILL_SRC" "$_skill_link" 2>/dev/null; then
    echo "  Linked $_skill_product skill to $_skill_link"
  elif [ "$(readlink "$_skill_link" 2>/dev/null)" = "$SKILL_SRC" ]; then
    :
  elif [ -L "$_skill_link" ] || [ -e "$_skill_link" ]; then
    echo "  Skipping $_skill_product skill install: $_skill_link exists and is not our symlink" >&2
  else
    echo "  Could not link $_skill_product skill to $_skill_link" >&2
    _skill_result=1
  fi

  rmdir "$_skill_lock" 2>/dev/null || _skill_result=1
  trap - EXIT HUP INT TERM
  return "$_skill_result"
}

_skill_install_failed=0
install_workspace_skill "Claude" "$HOME/.claude" "${WORKSPACE_SKIP_CLAUDE_SKILL:-0}" || _skill_install_failed=1
install_workspace_skill "Codex" "${CODEX_HOME:-$HOME/.codex}" "${WORKSPACE_SKIP_CODEX_SKILL:-0}" || _skill_install_failed=1
exit "$_skill_install_failed"
