#!/bin/sh
# Install the workspace CLI tool.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jnunemaker/workspace/main/install.sh | bash
#
# Installs to ~/.workspace/ and adds the bin directory to PATH via shell profile.

set -e

WORKSPACE_HOME="${WORKSPACE_HOME:-$HOME/.workspace}"
REPO_URL="https://github.com/jnunemaker/workspace.git"

echo "Installing workspace CLI..."

# Clone or update the repo
if [ -d "$WORKSPACE_HOME/.git" ]; then
  echo "  Updating existing installation..."
  git -C "$WORKSPACE_HOME" pull origin main --quiet
else
  if [ -d "$WORKSPACE_HOME" ]; then
    rm -rf "$WORKSPACE_HOME"
  fi
  echo "  Cloning workspace..."
  git clone --quiet "$REPO_URL" "$WORKSPACE_HOME"
fi

# Make the CLI executable
chmod +x "$WORKSPACE_HOME/bin/workspace"

# Add to PATH if not already there
BIN_DIR="$WORKSPACE_HOME/bin"
PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""

add_to_profile() {
  local profile="$1"
  if [ -f "$profile" ]; then
    if ! grep -qF "$BIN_DIR" "$profile" 2>/dev/null; then
      echo "" >> "$profile"
      echo "# workspace CLI" >> "$profile"
      echo "$PATH_LINE" >> "$profile"
      echo "  Added to $profile"
      return 0
    else
      echo "  Already in $profile"
      return 0
    fi
  fi
  return 1
}

# Try shell profiles in order of preference
PATH_ADDED=false
if [ -n "$ZSH_VERSION" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
  add_to_profile "$HOME/.zshrc" && PATH_ADDED=true
elif [ -n "$BASH_VERSION" ] || [ "$(basename "${SHELL:-}")" = "bash" ]; then
  add_to_profile "$HOME/.bashrc" && PATH_ADDED=true
  add_to_profile "$HOME/.bash_profile" 2>/dev/null || true
fi

# Fallback: try common profiles if nothing matched yet
if [ "$PATH_ADDED" = "false" ]; then
  add_to_profile "$HOME/.zshrc" 2>/dev/null ||
  add_to_profile "$HOME/.bashrc" 2>/dev/null ||
  add_to_profile "$HOME/.profile" 2>/dev/null ||
  echo "  Could not find a shell profile to update. Add this to your profile:"
  echo "    $PATH_LINE"
fi

sh "$WORKSPACE_HOME/lib/install_skill.sh"

VERSION=$(git -C "$WORKSPACE_HOME" log -1 --format="%h (%cs)" 2>/dev/null || echo "unknown")
echo ""
echo "workspace $VERSION installed successfully!"
echo ""
echo "Restart your terminal or run:"
echo "  export PATH=\"$BIN_DIR:\$PATH\""
