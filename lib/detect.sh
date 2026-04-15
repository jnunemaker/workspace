#!/bin/sh
# Auto-detection functions for workspace CLI.
# Sourced by subcommands that need to detect app characteristics.

# Detect database type from Gemfile.
# Sets: DB_TYPE ("postgresql" or "mysql")
detect_db_type() {
  DB_TYPE="postgresql"
  if [ -f Gemfile ]; then
    if grep -q '"mysql2"' Gemfile 2>/dev/null || grep -q "'mysql2'" Gemfile 2>/dev/null; then
      DB_TYPE="mysql"
    fi
  fi
}

# Detect if the app uses Caddy (reverse proxy).
# Sets: USES_CADDY (true/false)
detect_caddy() {
  USES_CADDY=false
  if [ -f Procfile.dev ] && grep -q "^caddy:" Procfile.dev 2>/dev/null; then
    USES_CADDY=true
  fi
}

# Detect if the app uses Vite (frontend bundler).
# Sets: USES_VITE (true/false)
detect_vite() {
  USES_VITE=false
  if [ -f Procfile.dev ] && grep -q "^vite:" Procfile.dev 2>/dev/null; then
    USES_VITE=true
  elif [ -f Gemfile ] && grep -q "vite_ruby" Gemfile 2>/dev/null; then
    USES_VITE=true
  fi
}

# Detect the app's setup script.
# Sets: SETUP_SCRIPT (path to the setup script, or empty)
detect_setup_script() {
  SETUP_SCRIPT=""
  if [ -x bin/setup ]; then
    SETUP_SCRIPT="bin/setup"
  elif [ -x script/setup ]; then
    SETUP_SCRIPT="script/setup"
  elif [ -x script/bootstrap ]; then
    SETUP_SCRIPT="script/bootstrap"
  fi
}

# Detect if foreman is available (gem or binstub).
# Sets: FOREMAN_CMD
detect_foreman() {
  if [ -x bin/foreman ]; then
    FOREMAN_CMD="bin/foreman"
  elif command -v foreman >/dev/null 2>&1; then
    FOREMAN_CMD="foreman"
  else
    FOREMAN_CMD=""
  fi
}
