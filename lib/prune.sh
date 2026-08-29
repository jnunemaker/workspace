#!/bin/sh
# workspace prune — Reconcile registered resources with live Git worktrees.

set -e

WORKSPACE_LIB="$(cd "$(dirname "$0")" && pwd)"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/registry.sh"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: workspace prune [--deferred]

Cleans up ports and databases recorded for Git worktrees that no longer exist.
Live Git worktrees are left alone.

Options:
  --deferred  Wait briefly so Git can finish removing the worktree
EOF
  exit 0
fi

_prune_mode="${1:-}"

if [ "$_prune_mode" = "--after-delay" ]; then
  [ -n "${2:-}" ] || exit 0
  _prune_root="$2"
  sleep 5
  cd "$_prune_root" 2>/dev/null || exit 0
  _prune_mode=""
fi

resolve_workspace

_registry_root=$(workspace_registry_root 2>/dev/null || true)
[ -n "$_registry_root" ] && [ -d "$_registry_root" ] || exit 0

if [ "$_prune_mode" = "--deferred" ]; then
  nohup sh "$WORKSPACE_LIB/prune.sh" --after-delay "$WORKSPACE_GIT_ROOT_PATH" \
    >/dev/null 2>&1 &
  exit 0
fi

acquire_workspace_registry_lock || exit 0
trap 'release_workspace_registry_lock' EXIT HUP INT TERM

# A killed prune may leave its immutable claim behind. A newer published record
# wins; otherwise restore the claim so this run can retry its cleanup.
for _orphaned_claim in "$_registry_root"/*.record.pruning.*; do
  [ -f "$_orphaned_claim" ] && [ ! -L "$_orphaned_claim" ] || continue
  _orphaned_entry=${_orphaned_claim%%.pruning.*}
  if [ -f "$_orphaned_entry" ]; then
    rm -f "$_orphaned_claim"
  else
    mv "$_orphaned_claim" "$_orphaned_entry"
  fi
done

if ! _live_worktrees=$(git -C "$WORKSPACE_GIT_ROOT_PATH" worktree list --porcelain 2>/dev/null); then
  [ "$_prune_mode" = "--quiet" ] || warn "Could not read Git worktree state — skipping cleanup"
  exit 0
fi

restore_claimed_record() {
  if [ -f "$_registry_entry" ]; then
    rm -f "$_claimed_entry"
  else
    mv "$_claimed_entry" "$_registry_entry"
  fi
}

for _registry_entry in "$_registry_root"/*.record; do
  [ -f "$_registry_entry" ] && [ ! -L "$_registry_entry" ] || continue
  _claimed_entry="$_registry_entry.pruning.$$"
  mv "$_registry_entry" "$_claimed_entry" 2>/dev/null || continue
  if ! load_registered_workspace "$_claimed_entry"; then
    restore_claimed_record
    continue
  fi

  _registered_path="$WORKSPACE_REGISTERED_PATH"

  if [ -d "$_registered_path" ]; then
    if printf '%s\n' "$_live_worktrees" | grep -Fqx "worktree $_registered_path"; then
      restore_claimed_record
      continue
    fi
    if ! _current_worktrees=$(git -C "$WORKSPACE_ROOT_PATH" worktree list --porcelain 2>/dev/null); then
      restore_claimed_record
      warn "Could not recheck Git worktree state — skipping $WORKSPACE_NAME"
      continue
    fi
    if printf '%s\n' "$_current_worktrees" | grep -Fqx "worktree $_registered_path"; then
      restore_claimed_record
      continue
    fi
  fi

  [ "$_prune_mode" = "--quiet" ] || header "Pruning removed workspace: $WORKSPACE_NAME"
  if ! sh "$WORKSPACE_LIB/archive.sh" --registry-entry "$_claimed_entry"; then
    restore_claimed_record
    warn "Cleanup failed for workspace $WORKSPACE_NAME — will retry later"
  fi
done
