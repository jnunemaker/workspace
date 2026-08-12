#!/bin/sh
# Database operations for workspace CLI.
# Sourced by bootstrap and archive subcommands.

# Patch config/database.yml to support workspace-specific database names.
# Lifecycle commands use WORKSPACE_DB_SUFFIX; ad-hoc Rails commands fall back
# to the same stable marker precedence used by the lifecycle resolver.
# Idempotent — skips if already patched.
install_workspace_suffix_helper() {
  local _database_patch_mode="${1:-helper}"
  WORKSPACE_DATABASE_PATCH_MODE="$_database_patch_mode" ruby -e '
    require "tempfile"
    require "yaml"

    def atomic_replace(path, content)
      mode = File.stat(path).mode & 0o7777
      temporary = Tempfile.new([".#{File.basename(path)}.", ".tmp"], File.dirname(path))
      temporary_path = temporary.path
      replaced = false
      begin
        temporary.binmode
        temporary.write(content)
        temporary.flush
        temporary.fsync
        temporary.close
        File.chmod(mode, temporary_path)
        File.rename(temporary_path, path)
        replaced = true
      ensure
        temporary.close unless temporary.closed?
        File.unlink(temporary_path) if !replaced && File.exist?(temporary_path)
      end
    end

    def workspace_database_base(token)
      value = YAML.safe_load(token, permitted_classes: [], aliases: false)
      raise "database name must be a YAML string scalar" unless value.is_a?(String)
      value
    end

    def workspace_database_argument(token)
      dynamic = token.match(/\A<%=\s*(.*?)\s*%>\z/m)
      dynamic ? dynamic[1] : workspace_database_base(token).dump
    end

    path = "config/database.yml"
    content = File.read(path)
    helper = <<~ERB
      <%
        require "json"
        require "open3"
        workspace_identity_helper_version = 2
        workspace_root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root : Dir.pwd
        conductor_identity_path = File.expand_path(".conductor-workspace", workspace_root)
        workspace_identity_path = File.expand_path(".workspace", workspace_root)

        provider_keys = %w[
          SUPERCONDUCTOR_ROOT_PATH SUPERCONDUCTOR_WORKSPACE_NAME
          SUPERSET_ROOT_PATH SUPERSET_WORKSPACE_NAME
          CONDUCTOR_ROOT_PATH CONDUCTOR_WORKSPACE_NAME
        ]
        provider_present = provider_keys.any? { |key| ENV.key?(key) && !ENV[key].to_s.empty? }
        provider_workspace_name = %w[
          SUPERCONDUCTOR_WORKSPACE_NAME SUPERSET_WORKSPACE_NAME CONDUCTOR_WORKSPACE_NAME
        ].map { |key| ENV[key] }.find { |name| name && !name.empty? }
        provider_default = provider_present && (provider_workspace_name.nil? || provider_workspace_name == "default")

        git_dir, git_status = Open3.capture2e("git", "-C", workspace_root.to_s, "rev-parse", "--git-dir")
        git_common_dir, git_common_status = Open3.capture2e("git", "-C", workspace_root.to_s, "rev-parse", "--git-common-dir")
        git_default = if git_status.success? && git_common_status.success?
          File.expand_path(git_dir.strip, workspace_root.to_s) ==
            File.expand_path(git_common_dir.strip, workspace_root.to_s)
        else
          true
        end
        default_checkout = provider_default || (!provider_present && git_default)

        unless default_checkout
          if File.symlink?(workspace_identity_path) || (File.exist?(workspace_identity_path) && !File.file?(workspace_identity_path))
            raise "Invalid non-regular .workspace identity"
          end
          if File.symlink?(conductor_identity_path) || (File.exist?(conductor_identity_path) && !File.file?(conductor_identity_path))
            raise "Invalid non-regular .conductor-workspace identity"
          end
        end

        workspace_db_suffix = ENV["WORKSPACE_DB_SUFFIX"]
        identity_path = if !default_checkout && File.file?(conductor_identity_path) && File.size?(conductor_identity_path)
          conductor_identity_path
        elsif !default_checkout && File.file?(workspace_identity_path)
          workspace_identity_path
        end
        if !workspace_db_suffix && identity_path
          workspace_name = File.read(identity_path).sub(/\\n+\\z/, "")
          if workspace_name.empty? || workspace_name == "default" || workspace_name.match?(/[[:cntrl:]]/)
            raise "Invalid \#{File.basename(identity_path)} identity"
          end
          workspace_db_suffix = "_\#{workspace_name}"
        end
        workspace_db_suffix ||= ""
        workspace_database_name = ->(base, suffix = workspace_db_suffix) {
          JSON.generate("\#{base}\#{suffix}")
        }
      %>
    ERB

    case ENV["WORKSPACE_DATABASE_PATCH_MODE"]
    when "legacy_env"
      content.gsub!(/<%=\s*ENV\[(["'\'' ])DEV_ENV_NUMBER\1\]\s*\|\|\s*[a-zA-Z_]\w*\s*%>/, "<%= ENV[\"DEV_ENV_NUMBER\"] || workspace_db_suffix %>")
      content.gsub!(/<%=\s*ENV\[(["'\'' ])TEST_ENV_NUMBER\1\]\s*\|\|\s*[a-zA-Z_]\w*\s*%>/, "<%= ENV[\"TEST_ENV_NUMBER\"] || workspace_db_suffix %>")
      content.gsub!(/<%=\s*ENV\[(["'\'' ])DEV_ENV_NUMBER\1\]\s*%>/, "<%= workspace_db_suffix %><%= ENV[\"DEV_ENV_NUMBER\"] %>")
      content.gsub!(/<%=\s*ENV\[(["'\'' ])TEST_ENV_NUMBER\1\]\s*%>/, "<%= workspace_db_suffix %><%= ENV[\"TEST_ENV_NUMBER\"] %>")
    when "plain_names"
      env = nil
      content = content.lines.map do |line|
        if line =~ /\A(development|test|staging|production):/
          env = $1.dup
        elsif line =~ /\A\S/ && line !~ /\A\s/
          env = nil
        end

        if (env == "development" || env == "test") && !line.include?("<%") &&
          (match = line.match(/\A(\s+database:\s*)(.+?)\s*$/))
          database_base = workspace_database_base(match[2])
          "#{match[1]}<%= workspace_database_name.call(#{database_base.dump}) %>\n"
        else
          line
        end
      end.join
    end

    content.gsub!(/<%=\s*ENV\[(["'\'' ])WORKSPACE_DB_SUFFIX\1\]\s*%>/, "<%= workspace_db_suffix %>")

    content = content.lines.map do |line|
      if (match = line.match(/\A(\s*database:\s*)(.+?)<%=\s*ENV\[(["'\''])(DEV_ENV_NUMBER|TEST_ENV_NUMBER)\3\]\s*\|\|\s*workspace_db_suffix\s*%>\s*$/))
        database_argument = workspace_database_argument(match[2].strip)
        "#{match[1]}<%= workspace_database_name.call(#{database_argument}, ENV[#{match[4].dump}] || workspace_db_suffix) %>\n"
      elsif (match = line.match(/\A(\s*database:\s*)(.+?)<%=\s*workspace_db_suffix\s*%><%=\s*ENV\[(["'\''])(DEV_ENV_NUMBER|TEST_ENV_NUMBER)\3\]\s*%>\s*$/))
        database_argument = workspace_database_argument(match[2].strip)
        "#{match[1]}<%= workspace_database_name.call(#{database_argument}, workspace_db_suffix + ENV[#{match[4].dump}].to_s) %>\n"
      elsif (match = line.match(/\A(\s*database:\s*)(.+?)<%=\s*workspace_db_suffix\s*%>\s*$/))
        database_argument = workspace_database_argument(match[2].strip)
        "#{match[1]}<%= workspace_database_name.call(#{database_argument}) %>\n"
      else
        line
      end
    end.join

    if content.include?("workspace_identity_path =")
      content.sub!(/\A<%\n.*?workspace_identity_path =.*?^\s*%>\n/m, helper)
    else
      content = helper + content
    end
    atomic_replace(path, content)
  '
}

patch_database_yml() {
  local db_yml="config/database.yml"

  if [ ! -f "$db_yml" ]; then
    warn "config/database.yml not found — skipping database patch"
    return
  fi

  # Already uses the current stable-marker helper and quotes generated YAML.
  if grep -q 'workspace_identity_helper_version = 2' "$db_yml" 2>/dev/null && \
    grep -q 'workspace_database_name.call' "$db_yml" 2>/dev/null; then
    step "database.yml already supports workspace isolation"
    return
  fi

  # Upgrade a previous helper in place so root-checkout detection and YAML
  # quoting stay aligned with current lifecycle commands.
  if grep -q 'workspace_identity_path =' "$db_yml" 2>/dev/null; then
    step "Upgrading stable workspace identity fallback in database.yml"
    install_workspace_suffix_helper || return 1
    ok "database.yml updated"
    return
  fi

  # Upgrade earlier Workspace patches so bare Rails commands use the same DB.
  if grep -q 'WORKSPACE_DB_SUFFIX' "$db_yml" 2>/dev/null; then
    step "Adding stable workspace identity fallback to database.yml"
    install_workspace_suffix_helper || return 1
    ok "database.yml updated"
    return
  fi

  # Inject WORKSPACE_DB_SUFFIX before existing ENV_NUMBER vars
  if grep -q 'DEV_ENV_NUMBER\|TEST_ENV_NUMBER' "$db_yml" 2>/dev/null; then
    step "Adding WORKSPACE_DB_SUFFIX to database.yml (preserving existing env vars)"
    install_workspace_suffix_helper legacy_env || return 1
    ok "database.yml updated"
    return
  fi

  # Also check for DB_SUFFIX (fireside pattern)
  if grep -q 'DB_SUFFIX' "$db_yml" 2>/dev/null; then
    step "database.yml already supports workspace isolation (DB_SUFFIX)"
    return
  fi

  step "Patching database.yml for workspace isolation"
  install_workspace_suffix_helper plain_names || return 1

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
