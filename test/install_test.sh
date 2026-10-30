#!/bin/sh
# Tests for install.sh, the curl | bash installer.

cd "$(dirname "$0")"
. ./test_helper.sh

installer="$WORKSPACE_HOME/install.sh"
fake_bin="$TEST_TMP/bin"
git_log="$TEST_TMP/git-calls"
mkdir -p "$fake_bin"

# Fake git: record every call, and make `clone` lay down just enough of a
# checkout for the rest of the installer to run.
cat > "$fake_bin/git" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
if [ "$1" = "clone" ]; then
  for dest; do :; done
  mkdir -p "$dest/bin" "$dest/lib"
  printf '#!/bin/sh\n' > "$dest/bin/workspace"
  printf 'printf "skill\\n" >> "$FAKE_GIT_LOG"\n' > "$dest/lib/install_skill.sh"
fi
SCRIPT
chmod +x "$fake_bin/git"

# Run installer text from stdin the way the README does, in a fresh fake HOME.
run_piped() {
  local shell="$1" home="$2"
  rm -rf "$home" "$git_log"
  mkdir -p "$home"
  : > "$home/.zshrc"
  env -i PATH="$fake_bin:/usr/bin:/bin" HOME="$home" SHELL=/bin/zsh \
    WORKSPACE_HOME="$home/.workspace" FAKE_GIT_LOG="$git_log" \
    "$shell" >/dev/null 2>&1
}

# A full download installs: clones, updates the profile, links the skill.
home="$TEST_TMP/home-full"
run_piped bash "$home" < "$installer"
assert_true "full install clones the repo" grep -q '^clone ' "$git_log"
assert_true "full install runs the skill installer" grep -qx 'skill' "$git_log"
assert_true "full install adds bin to PATH in .zshrc" grep -qF "$home/.workspace/bin" "$home/.zshrc"

# A download cut off at any line boundary runs nothing at all.
total=$(wc -l < "$installer" | tr -d ' ')
for shell in bash sh; do
  partial_ran=""
  n=1
  while [ "$n" -lt "$total" ]; do
    home="$TEST_TMP/home-$shell-$n"
    head -n "$n" "$installer" | run_piped "$shell" "$home"
    if [ -s "$git_log" ] || [ -e "$home/.workspace" ] || [ -s "$home/.zshrc" ]; then
      partial_ran="$partial_ran $n"
    fi
    n=$((n + 1))
  done
  assert_equal "truncated install via $shell runs nothing (lines that acted:$partial_ran)" "" "$partial_ran"
done

# An install that is a linked Git worktree (.git is a file) is updated with git,
# never removed and cloned again.
home="$TEST_TMP/home-worktree"
rm -f "$git_log"
mkdir -p "$home/.workspace/bin" "$home/.workspace/lib"
: > "$home/.zshrc"
printf 'gitdir: /somewhere/.git/worktrees/dev\n' > "$home/.workspace/.git"
printf '#!/bin/sh\n' > "$home/.workspace/bin/workspace"
: > "$home/.workspace/lib/install_skill.sh"
printf 'uncommitted\n' > "$home/.workspace/notes.txt"
env -i PATH="$fake_bin:/usr/bin:/bin" HOME="$home" SHELL=/bin/zsh \
  WORKSPACE_HOME="$home/.workspace" FAKE_GIT_LOG="$git_log" \
  bash < "$installer" >/dev/null 2>&1
assert_true "worktree install pulls with git" grep -q ' pull origin main' "$git_log"
assert_false "worktree install does not clone" grep -q '^clone ' "$git_log"
assert_true "worktree install keeps the checkout's files" [ -f "$home/.workspace/notes.txt" ]

report "install.sh"
