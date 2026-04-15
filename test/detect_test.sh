#!/bin/sh
# Tests for lib/detect.sh — auto-detection functions.

cd "$(dirname "$0")"
. ./test_helper.sh

# ── detect_db_type ───────────────────────────────────────────────

# PostgreSQL (default when no Gemfile)
app_dir=$(create_fake_app "pg-app")
cd "$app_dir"
rm -f Gemfile
detect_db_type
assert_equal "no Gemfile → postgresql" "postgresql" "$DB_TYPE"

# PostgreSQL from Gemfile
app_dir=$(create_fake_app "pg-app2")
cd "$app_dir"
echo 'gem "pg"' >> Gemfile
detect_db_type
assert_equal "pg gem → postgresql" "postgresql" "$DB_TYPE"

# MySQL from Gemfile
app_dir=$(create_fake_app "mysql-app")
cd "$app_dir"
echo 'gem "mysql2"' >> Gemfile
detect_db_type
assert_equal "mysql2 gem → mysql" "mysql" "$DB_TYPE"

# ── detect_caddy ─────────────────────────────────────────────────

# No Procfile.dev
app_dir=$(create_fake_app "no-procfile")
cd "$app_dir"
detect_caddy
assert_equal "no Procfile.dev → no caddy" "false" "$USES_CADDY"

# Procfile.dev without caddy
app_dir=$(create_fake_app "no-caddy")
cd "$app_dir"
echo "web: bin/rails server" > Procfile.dev
detect_caddy
assert_equal "no caddy line → false" "false" "$USES_CADDY"

# Procfile.dev with caddy
app_dir=$(create_fake_app "with-caddy")
cd "$app_dir"
printf "web: bin/rails server\ncaddy: caddy run" > Procfile.dev
detect_caddy
assert_equal "caddy line → true" "true" "$USES_CADDY"

# ── detect_vite ──────────────────────────────────────────────────

# From Procfile.dev
app_dir=$(create_fake_app "vite-procfile")
cd "$app_dir"
printf "web: bin/rails server\nvite: bin/vite dev" > Procfile.dev
detect_vite
assert_equal "vite in Procfile.dev → true" "true" "$USES_VITE"

# From Gemfile
app_dir=$(create_fake_app "vite-gemfile")
cd "$app_dir"
echo 'gem "vite_ruby"' >> Gemfile
detect_vite
assert_equal "vite_ruby in Gemfile → true" "true" "$USES_VITE"

# Neither
app_dir=$(create_fake_app "no-vite")
cd "$app_dir"
detect_vite
assert_equal "no vite → false" "false" "$USES_VITE"

# ── detect_setup_script ──────────────────────────────────────────

# bin/setup (preferred)
app_dir=$(create_fake_app "setup-bin")
cd "$app_dir"
chmod +x bin/setup 2>/dev/null || touch bin/setup && chmod +x bin/setup
detect_setup_script
assert_equal "bin/setup found" "bin/setup" "$SETUP_SCRIPT"

# script/setup fallback
app_dir=$(create_fake_app "setup-script")
cd "$app_dir"
mkdir -p script
touch script/setup && chmod +x script/setup
detect_setup_script
assert_equal "script/setup fallback" "script/setup" "$SETUP_SCRIPT"

# script/bootstrap fallback
app_dir=$(create_fake_app "setup-bootstrap")
cd "$app_dir"
mkdir -p script
touch script/bootstrap && chmod +x script/bootstrap
detect_setup_script
assert_equal "script/bootstrap fallback" "script/bootstrap" "$SETUP_SCRIPT"

# No setup script
app_dir=$(create_fake_app "no-setup")
cd "$app_dir"
rm -f bin/setup
detect_setup_script
assert_equal "no setup script → empty" "" "$SETUP_SCRIPT"

report "detect.sh"
