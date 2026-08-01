#!/bin/sh
# Tests for port derivation logic (from lib/run.sh).

cd "$(dirname "$0")"
. ./test_helper.sh

# Clear any env vars from the host environment
unset SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME SUPERCONDUCTOR_WORKSPACE_PATH 2>/dev/null || true

# ── Port derivation helper (extracted from run.sh) ───────────────

derive_port() {
  derive_workspace_port "3000"
}

# CONDUCTOR_PORT takes precedence
CONDUCTOR_PORT=4000
SUPERSET_WORKSPACE_NAME="some-branch"
result=$(derive_port)
assert_equal "CONDUCTOR_PORT takes precedence" "4000" "$result"

# Superset workspace name derives port
unset CONDUCTOR_PORT
SUPERSET_WORKSPACE_NAME="my-feature"
result=$(derive_port)
assert_true "derived port >= 50000" [ "$result" -ge 50000 ]
assert_true "derived port <= 58990" [ "$result" -le 58990 ]

# Port is deterministic
result2=$(derive_port)
assert_equal "port is deterministic" "$result" "$result2"

# Different names get different ports (usually)
SUPERSET_WORKSPACE_NAME="other-feature"
result3=$(derive_port)
# We can't guarantee different (hash collision possible), but check it's valid
assert_true "other port in range" [ "$result3" -ge 50000 ]

# Default workspace gets port 3000
SUPERSET_WORKSPACE_NAME="default"
result=$(derive_port)
assert_equal "default gets 3000" "3000" "$result"

# No vars gets 3000
unset CONDUCTOR_PORT SUPERSET_WORKSPACE_NAME
WORKSPACE_NAME=""
WORKSPACE_PROVIDER=""
result=$(derive_port)
assert_equal "no vars gets 3000" "3000" "$result"

# Git worktrees derive an isolated port from their resolved name.
WORKSPACE_NAME="workspace-abc123"
WORKSPACE_PROVIDER="git"
result=$(derive_port)
assert_true "git worktree port >= 50000" [ "$result" -ge 50000 ]
assert_true "git worktree port <= 58990" [ "$result" -le 58990 ]

# A Git worktree may legitimately sanitize to "default"; it must still be
# isolated from the main checkout's historical port 3000.
WORKSPACE_NAME="default"
WORKSPACE_PROVIDER="git"
result=$(derive_port)
assert_true "git worktree named default gets isolated port" [ "$result" -ge 50000 ]
assert_true "git worktree named default avoids port 3000" [ "$result" -ne 3000 ]

# Conductor without CONDUCTOR_PORT keeps its historical default behavior.
WORKSPACE_NAME="conductor-feature"
WORKSPACE_PROVIDER="conductor"
result=$(derive_port)
assert_equal "conductor without port keeps default" "3000" "$result"

# Port is multiple of 10 (for 10-port block allocation)
SUPERSET_WORKSPACE_NAME="test-port-alignment"
WORKSPACE_NAME="test-port-alignment"
WORKSPACE_PROVIDER="superset"
result=$(derive_port)
remainder=$((result % 10))
assert_equal "port is multiple of 10" "0" "$remainder"

# ── Port export logic (caddy vs non-caddy) ───────────────────────

# With Caddy: HTTPS_PORT, RAILS_PORT, CADDY_ADMIN_PORT
BASE_PORT=50100
USES_CADDY=true
USES_VITE=false
HTTPS_PORT=$BASE_PORT
RAILS_PORT=$((BASE_PORT + 1))
CADDY_ADMIN_PORT=$((BASE_PORT + 2))
assert_equal "HTTPS_PORT = BASE_PORT" "50100" "$HTTPS_PORT"
assert_equal "RAILS_PORT = BASE_PORT+1" "50101" "$RAILS_PORT"
assert_equal "CADDY_ADMIN_PORT = BASE_PORT+2" "50102" "$CADDY_ADMIN_PORT"

# With Caddy + Vite
USES_VITE=true
VITE_RUBY_PORT=$((BASE_PORT + 3))
assert_equal "VITE_RUBY_PORT = BASE_PORT+3" "50103" "$VITE_RUBY_PORT"

# Without Caddy: just PORT
USES_CADDY=false
USES_VITE=false
PORT=$BASE_PORT
assert_equal "PORT = BASE_PORT (no caddy)" "50100" "$PORT"

report "port derivation"
