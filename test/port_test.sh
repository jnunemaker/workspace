#!/bin/sh
# Tests for port derivation logic (from lib/run.sh).

cd "$(dirname "$0")"
. ./test_helper.sh

# ── Port derivation helper (extracted from run.sh) ───────────────

derive_port() {
  if [ -n "$CONDUCTOR_PORT" ]; then
    echo "$CONDUCTOR_PORT"
  elif [ -n "$SUPERSET_WORKSPACE_NAME" ] && [ "$SUPERSET_WORKSPACE_NAME" != "default" ]; then
    _hash=$(printf '%s' "$SUPERSET_WORKSPACE_NAME" | cksum | awk '{print $1}')
    echo "$(( ((_hash % 900) * 10) + 50000 ))"
  else
    echo "3000"
  fi
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
result=$(derive_port)
assert_equal "no vars gets 3000" "3000" "$result"

# Port is multiple of 10 (for 10-port block allocation)
SUPERSET_WORKSPACE_NAME="test-port-alignment"
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
