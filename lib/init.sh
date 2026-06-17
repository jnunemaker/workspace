#!/bin/sh
# workspace init — Set up a project to work with workspace CLI.
#
# Flow:
#   1. Patch database.yml for workspace isolation (idempotent)
#   2. Create .conductor/settings.toml (migrating a legacy conductor.json)
#   3. Create .superconductor/config.json
#   4. Create .superset/config.json
#   5. Create bin/workspace-seed (commented scaffold)
#   6. Add .workspace to .gitignore

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/db.sh"

# Convert a legacy conductor.json (in the current directory) into the body of
# .conductor/settings.toml, printed on stdout. Uses Ruby so JSON string escaping
# survives and every repo setting is preserved — not just scripts. Adds the
# default workspace scripts only when none are present. Exits non-zero (printing
# nothing) when conductor.json is missing, malformed, or uses a structure we
# can't migrate faithfully, so the caller can leave the original in place.
_conductor_json_to_toml() {
  ruby -e '
    require "json"

    def esc(s)
      "\"" + s.gsub(/[\x00-\x1f\\"]/) { |c|
        case c
        when "\\" then "\\\\"
        when "\"" then "\\\""
        when "\n" then "\\n"
        when "\t" then "\\t"
        when "\r" then "\\r"
        else "\\u%04X" % c.ord
        end
      } + "\""
    end

    def tkey(k)
      k =~ /\A[A-Za-z0-9_-]+\z/ ? k : esc(k)
    end

    def tval(v)
      case v
      when String then esc(v)
      when true, false then v.to_s
      when Integer, Float then v.to_s
      when Array
        raise "unsupported array" unless v.all? { |e| String === e || true == e || false == e || Numeric === e }
        "[" + v.map { |e| tval(e) }.join(", ") + "]"
      else
        raise "unsupported value"
      end
    end

    data = JSON.parse(File.read("conductor.json"))
    raise "not an object" unless Hash === data
    unless data.key?("$schema")
      data = { "$schema" => "https://conductor.build/schemas/settings.repo.schema.json" }.merge(data)
    end
    s = data["scripts"]
    if s.nil? || (Hash === s && s.empty?)
      data["scripts"] = { "setup" => "workspace bootstrap", "run" => "workspace run", "archive" => "workspace archive" }
    end

    scalars, tables = [], []
    data.each { |k, v| (Hash === v ? tables : scalars) << [k, v] }

    out = []
    scalars.each { |k, v| out << "#{tkey(k)} = #{tval(v)}" }
    tables.each do |k, tbl|
      out << ""
      out << "[#{tkey(k)}]"
      tbl.each do |kk, vv|
        raise "nested table" if Hash === vv
        out << "#{tkey(kk)} = #{tval(vv)}"
      end
    end
    print out.join("\n") + "\n"
  '
}

header "Initializing workspace support"

# ── Patch database.yml ──────────────────────────────────────────

patch_database_yml

# ── Create .conductor/settings.toml ─────────────────────────────

if [ -f .conductor/settings.toml ]; then
  step ".conductor/settings.toml already exists"
elif [ -f conductor.json ]; then
  # Conductor moved repo config from conductor.json to .conductor/settings.toml.
  # Convert the whole file, and only drop the legacy one once it has migrated.
  if _toml=$(_conductor_json_to_toml 2>/dev/null) && [ -n "$_toml" ]; then
    mkdir -p .conductor
    printf '%s\n' "$_toml" > .conductor/settings.toml
    rm -f conductor.json
    ok "Migrated conductor.json → .conductor/settings.toml"
  else
    warn "Couldn't safely migrate conductor.json — left it in place."
    warn "Copy its settings into .conductor/settings.toml by hand, then delete it."
  fi
else
  mkdir -p .conductor
  cat > .conductor/settings.toml <<'EOF'
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

[scripts]
setup = "workspace bootstrap"
run = "workspace run"
archive = "workspace archive"
EOF
  ok "Created .conductor/settings.toml"
fi

# ── Create .superconductor/config.json ──────────────────────────

if [ -f .superconductor/config.json ]; then
  step ".superconductor/config.json already exists"
else
  mkdir -p .superconductor
  cat > .superconductor/config.json <<'EOF'
{
  "setup": ["workspace bootstrap"],
  "run": ["workspace run"]
}
EOF
  ok "Created .superconductor/config.json"
fi

# ── Create .superset/config.json ────────────────────────────────

if [ -f .superset/config.json ]; then
  step ".superset/config.json already exists"
else
  mkdir -p .superset
  cat > .superset/config.json <<'EOF'
{
  "setup": ["workspace bootstrap"],
  "teardown": ["workspace archive"]
}
EOF
  ok "Created .superset/config.json"
fi

# ── Create bin/workspace-seed ────────────────────────────────────

if [ -f bin/workspace-seed ]; then
  step "bin/workspace-seed already exists"
else
  cat > bin/workspace-seed <<'EOF'
#!/bin/sh
# Seed the workspace database after schema load.
# Uncomment the line that matches your project's seed strategy.
#
# Fixtures (test data loaded into dev):
#   bin/rails db:fixtures:load
#
# Seeds file (db/seeds.rb):
#   bin/rails db:seed
#
# Custom rake task:
#   bin/rails plan:seed
#
# Nothing needed? Delete this file.

EOF
  chmod +x bin/workspace-seed
  ok "Created bin/workspace-seed (edit to configure seeding)"
fi

# ── Add .workspace to .gitignore ────────────────────────────────

if [ -f .gitignore ] && grep -qxF '.workspace' .gitignore; then
  step ".workspace already in .gitignore"
elif [ -f .gitignore ]; then
  [ -z "$(tail -c1 .gitignore 2>/dev/null)" ] || printf '\n' >> .gitignore
  printf '.workspace\n' >> .gitignore
  ok "Added .workspace to .gitignore"
else
  printf '.workspace\n' > .gitignore
  ok "Created .gitignore with .workspace"
fi

printf "\n${_green}  ✓${_reset} ${_bold}Project is now workspace-ready${_reset}\n"
