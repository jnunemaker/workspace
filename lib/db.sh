#!/bin/sh
# Database operations for workspace CLI.
# Sourced by bootstrap and archive subcommands.

# Patch config/database.yml to support workspace-specific database names.
# Adds ERB suffixes using WORKSPACE_DB_SUFFIX.
# Idempotent — skips if already patched.
patch_database_yml() {
  local db_yml="config/database.yml"

  if [ ! -f "$db_yml" ]; then
    warn "config/database.yml not found — skipping database patch"
    return
  fi

  # Already patched?
  if grep -q 'WORKSPACE_DB_SUFFIX' "$db_yml" 2>/dev/null; then
    step "database.yml already supports workspace isolation"
    return
  fi

  # Inject WORKSPACE_DB_SUFFIX before existing ENV_NUMBER vars
  if grep -q 'DEV_ENV_NUMBER\|TEST_ENV_NUMBER' "$db_yml" 2>/dev/null; then
    step "Adding WORKSPACE_DB_SUFFIX to database.yml (preserving existing env vars)"
    sed -i '' \
      -e 's/<%= ENV\["DEV_ENV_NUMBER"\] %>/<%= ENV["WORKSPACE_DB_SUFFIX"] %><%= ENV["DEV_ENV_NUMBER"] %>/g' \
      -e 's/<%= ENV\["TEST_ENV_NUMBER"\] %>/<%= ENV["WORKSPACE_DB_SUFFIX"] %><%= ENV["TEST_ENV_NUMBER"] %>/g' \
      "$db_yml"
    ok "database.yml updated"
    return
  fi

  # Also check for DB_SUFFIX (fireside pattern)
  if grep -q 'DB_SUFFIX' "$db_yml" 2>/dev/null; then
    step "database.yml already supports workspace isolation (DB_SUFFIX)"
    return
  fi

  step "Patching database.yml for workspace isolation"

  # Use Ruby for reliable YAML manipulation that handles multi-database configs.
  # This adds ERB suffixes to development and test database names.
  ruby -e '
    content = File.read("config/database.yml")
    lines = content.lines
    env = nil
    result = []

    lines.each do |line|
      # Track which top-level environment we are in
      if line =~ /\A(development|test|staging|production):/
        env = $1.dup
        result << line
        next
      elsif line =~ /\A\S/ && line !~ /\A\s/
        env = nil
        result << line
        next
      end

      # Only patch development and test database lines
      if (env == "development" || env == "test") && !line.include?("<%")
        if m = line.match(/\A(\s+database:\s*)(\S+)\s*$/)
          result << "#{m[1]}#{m[2]}<%= ENV[\"WORKSPACE_DB_SUFFIX\"] %>\n"
          next
        end
      end

      result << line
    end

    File.write("config/database.yml", result.join)
  '

  ok "database.yml patched"
}

# Create workspace-specific databases.
create_workspace_databases() {
  if is_default_workspace; then
    return
  fi

  export WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}"

  header "Creating workspace databases"

  step "Dev database"
  RAILS_ENV=development bin/rails db:create 2>/dev/null || true
  RAILS_ENV=development bin/rails db:schema:load 2>/dev/null || true
  ok "Dev database ready"

  step "Test database"
  RAILS_ENV=test bin/rails db:create 2>/dev/null || true
  RAILS_ENV=test bin/rails db:schema:load 2>/dev/null || true
  ok "Test database ready"

  # Seed
  if [ -x bin/workspace-seed ]; then
    step "Seeding"
    bin/workspace-seed
    ok "Seeded"
  fi
}

# Drop workspace-specific databases.
drop_workspace_databases() {
  if is_default_workspace; then
    return
  fi

  export WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}"

  header "Dropping workspace databases"

  step "Dropping dev database"
  RAILS_ENV=development bin/rails db:drop 2>/dev/null || true
  ok "Dev database dropped"

  step "Dropping test database"
  RAILS_ENV=test bin/rails db:drop 2>/dev/null || true
  ok "Test database dropped"
}
