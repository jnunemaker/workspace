#!/bin/sh
# Auto-detection functions for workspace CLI.
# Sourced by subcommands that need to detect app characteristics.

# Detect if the app uses Caddy (reverse proxy).
# Sets: USES_CADDY (true/false)
detect_caddy() {
  USES_CADDY=false
  if [ -f Procfile.dev ] && grep -q "^caddy:" Procfile.dev 2>/dev/null; then
    USES_CADDY=true
  fi
}

# Print the first concrete hostname the Procfile.dev caddy process serves,
# or nothing when it cannot be read.
caddy_host() {
  caddy_site_host "$(caddy_config_path)"
}

# Print the Caddyfile the Procfile.dev caddy process loads. Caddy reads
# ./Caddyfile without --config; JSON and other adapters print nothing.
caddy_config_path() {
  awk '
    /^caddy:/ {
      sub(/\r$/, "")
      gsub(/["\047]/, "")
      gsub(/--config=/, "--config ")
      gsub(/--adapter=/, "--adapter ")
      config = "Caddyfile"
      adapter = ""
      for (i = 2; i < NF; i++) {
        if ($i == "--config") config = $(++i)
        else if ($i == "--adapter") adapter = $(++i)
      }
      if (adapter != "" && adapter != "caddyfile") exit
      if (config ~ /[$]/ || config ~ /\.json$/) exit
      print config
      exit
    }
  ' Procfile.dev 2>/dev/null
}

# Print the first concrete hostname a Caddyfile serves over HTTPS, preferring
# a named host over bare localhost or an IP address, which projects commonly
# list first only to redirect or catch stray requests. Site addresses are the
# top-level tokens that open a block, or the first top-level line of a
# braceless single-site Caddyfile. The global options block, import, snippets,
# named routes, placeholders, wildcards, port-only and HTTP-only addresses are
# skipped because none names a host the HTTPS URL can use.
caddy_site_host() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  awk '
    function host(address) {
      sub(/,$/, "", address)
      gsub(/["`]/, "", address)
      if (address ~ /^http:\/\// || address ~ /:80(\/|$)/) return ""
      sub(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "", address)
      sub(/\/.*/, "", address)
      sub(/:([0-9]*|\{[^{}]*\})$/, "", address)
      if (address ~ /[][{}*$]/) return ""
      return tolower(address)
    }
    function serve(  i, name) {
      for (i = 1; i <= count; i++) {
        if ((name = host(addresses[i])) == "") continue
        if (name == "localhost" || name ~ /^[0-9.]+$/) {
          if (fallback == "") fallback = name
          continue
        }
        print name
        named = 1
        exit
      }
    }
    END { if (!named && fallback != "") print fallback }
    {
      sub(/\r$/, "")
      sub(/(^|[ \t])#.*/, "")
      for (i = 1; i <= NF; i++) {
        if ($i == "{") {
          if (!depth && count && !skip) { sites++; serve() }
          depth++; count = 0
          continue
        }
        if ($i == "}") { depth--; continue }
        if (depth) continue
        if (!count) skip = ($i == "import" || $i ~ /^&?\(/)
        addresses[++count] = $i
      }
      if (depth || !count) next
      if ($NF ~ /,$/) next
      # A complete top-level line without a block is an import, or the
      # addresses of a braceless single site whose remaining lines are
      # directives rather than addresses.
      if (!skip && !sites) { serve(); exit }
      count = 0
    }
  ' "$1" 2>/dev/null
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
