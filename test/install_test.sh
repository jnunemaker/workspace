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
  eval "dest=\${$#}"
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
    rm -rf "$home"
    n=$((n + 1))
  done
  assert_equal "truncated install via $shell runs nothing (lines that acted:$partial_ran)" "" "$partial_ran"
done

report "install.sh"
