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

# Prepare workspace-specific databases.
prepare_workspace_database() {
  local _database_environment _database_tasks
  _database_environment="$1"

  if RAILS_ENV="$_database_environment" bin/rails db:prepare; then
    return 0
  fi

  # Rails versions without db:prepare retain a data-preserving fallback. Only
  # use it when the task inventory succeeds and confirms the task is absent;
  # an actual db:prepare failure must still propagate.
  if _database_tasks=$(RAILS_ENV="$_database_environment" bin/rails --tasks 2>/dev/null) && \
    ! printf '%s\n' "$_database_tasks" | grep -q 'db:prepare'; then
    RAILS_ENV="$_database_environment" bin/rails db:create && \
      RAILS_ENV="$_database_environment" bin/rails db:migrate
    return
  fi

  return 1
}

create_workspace_databases() {
  if is_default_workspace; then
    return 0
  fi
  if [ "$WORKSPACE_NAME" = "default" ]; then
    err "Refusing to prepare databases with the reserved workspace name 'default'"
    return 1
  fi
  export WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}"

  if [ -x bin/rails ]; then
    header "Preparing workspace databases"

    _prepare_failed=0

    step "Dev database"
    if prepare_workspace_database development; then
      ok "Dev database ready"
    else
      warn "Could not prepare dev database"
      _prepare_failed=1
    fi

    step "Test database"
    if prepare_workspace_database test; then
      ok "Test database ready"
    else
      warn "Could not prepare test database"
      _prepare_failed=1
    fi

    [ "$_prepare_failed" -eq 0 ] || return 1
  else
    step "No Rails executable — skipping database preparation"
  fi

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
    return 0
  fi
  if [ "$WORKSPACE_NAME" = "default" ]; then
    err "Refusing to drop databases with the reserved workspace name 'default'"
    return 1
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

# Drop databases for unattended reconciliation. Unlike the legacy archive path,
# failures are returned so the registry record can be retained for a retry.
drop_workspace_databases_strict() {
  if is_default_workspace; then
    return 0
  fi
  if [ "$WORKSPACE_NAME" = "default" ]; then
    err "Refusing to drop databases with the reserved workspace name 'default'"
    return 1
  fi

  if [ ! -x bin/rails ] || [ ! -f config/database.yml ]; then
    step "No Rails database configuration — skipping database cleanup"
    return 0
  fi

  export WORKSPACE_DB_SUFFIX="_${WORKSPACE_NAME}"
  _drop_failed=0

  header "Dropping workspace databases"

  step "Dropping dev database"
  if RAILS_ENV=development bin/rails db:drop 2>/dev/null; then
    ok "Dev database dropped"
  else
    warn "Could not drop dev database"
    _drop_failed=1
  fi

  step "Dropping test database"
  if RAILS_ENV=test bin/rails db:drop 2>/dev/null; then
    ok "Test database dropped"
  else
    warn "Could not drop test database"
    _drop_failed=1
  fi

  [ "$_drop_failed" -eq 0 ]
}
