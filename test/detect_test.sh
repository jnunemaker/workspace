#!/bin/sh
# Tests for lib/detect.sh — auto-detection functions.

cd "$(dirname "$0")"
. ./test_helper.sh

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

assert_caddy_host() {
  assert_equal "$1" "$2" "$(caddy_host)"
}

assert_caddy_host "missing Caddyfile → no host" ""

# The served host comes from the site addresses, after the global options
# block and snippets, never from the checkout directory name.
cat > Caddyfile <<'EOF'
# Local development proxy
{
  admin localhost:{$CADDY_ADMIN_PORT:2019}
  https_port {$HTTPS_PORT:3000}
}

(proxy) {
  reverse_proxy localhost:{$RAILS_PORT:3001}
}

:80 {$EXTRA_HOST}, *.wild.localhost,
  https://Project.localhost:443/path, bxout.localhost {
  import proxy
}
EOF
assert_caddy_host "Caddyfile site → first concrete host" "project.localhost"

printf 'example.localhost\nreverse_proxy localhost:3001\n' > Caddyfile
assert_caddy_host "single-site Caddyfile without braces → host" "example.localhost"

mkdir -p config
printf 'from-config.localhost {\n}\n' > config/Caddyfile.dev
printf "caddy: caddy run --config 'config/Caddyfile.dev' --adapter=caddyfile\n" > Procfile.dev
assert_caddy_host "--config Caddyfile → host" "from-config.localhost"

printf 'caddy: caddy run --config=config/Caddyfile.dev\n' > Procfile.dev
assert_caddy_host "--config= Caddyfile → host" "from-config.localhost"

printf 'caddy: caddy run --config caddy.json\n' > Procfile.dev
printf '{"apps":{}}\n' > caddy.json
assert_caddy_host "JSON config → no host" ""

printf 'caddy: caddy run --config $CADDYFILE\n' > Procfile.dev
assert_caddy_host "variable config path → no host" ""

printf 'caddy: caddy run\n' > Procfile.dev
printf ':443 {\n}\n' > Caddyfile
assert_caddy_host "port-only site → no host" ""

printf 'import common.caddy\n\napp.localhost {\n}\n' > Caddyfile
assert_caddy_host "top-level import is not a host" "app.localhost"

printf 'import common.caddy\napp.localhost\nreverse_proxy localhost:3001\n' > Caddyfile
assert_caddy_host "import before braceless site → host" "app.localhost"

printf '{\n  admin off\n}\napp.localhost\nreverse_proxy localhost:3001\n' > Caddyfile
assert_caddy_host "global options before braceless site → host" "app.localhost"

printf '(proxy) {\n  reverse_proxy localhost:3001\n}\napp.localhost\nimport proxy\n' > Caddyfile
assert_caddy_host "snippet before braceless site → host" "app.localhost"

printf 'app.localhost:{$HTTPS_PORT:3000} {\n}\n' > Caddyfile
assert_caddy_host "placeholder port keeps host" "app.localhost"

printf '"app.localhost" {\n}\n' > Caddyfile
assert_caddy_host "quoted site address → host" "app.localhost"

printf 'localhost, 127.0.0.1 {\n}\nhttp://localhost {\n}\nlocalhost, project.localhost {\n}\n' > Caddyfile
assert_caddy_host "named host preferred over localhost" "project.localhost"

printf '127.0.0.1, localhost {\n}\n' > Caddyfile
assert_caddy_host "only localhost or IPs → first one" "127.0.0.1"

printf ':80\nreverse_proxy localhost:3001\n' > Caddyfile
assert_caddy_host "braceless directives are not hosts" ""

printf 'http://plain.localhost {\n}\napp.localhost:80, secure.localhost {\n}\n' > Caddyfile
assert_caddy_host "HTTP-only addresses are skipped" "secure.localhost"

printf '{\r\n  admin off\r\n}\r\napp.localhost {\r\n}\r\n' > Caddyfile
printf 'caddy: caddy run --config Caddyfile --adapter caddyfile\r\n' > Procfile.dev
assert_caddy_host "CRLF Procfile.dev and Caddyfile → host" "app.localhost"

printf 'caddy: caddy run\n' > Procfile.dev
printf 'linked.localhost {\n}\n' > shared.caddy
rm Caddyfile
ln -s shared.caddy Caddyfile
assert_caddy_host "symlinked Caddyfile → host" "linked.localhost"

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
