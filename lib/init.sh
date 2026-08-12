#!/bin/sh
# workspace init — Set up a project to work with workspace CLI.
#
# Flow:
#   1. Patch database.yml for workspace isolation (idempotent)
#   2. Create the project-local bin/workspace entrypoint and version contract
#   3. Create/update provider lifecycle configs to use that entrypoint
#   4. Add .workspace to .gitignore

set -e

WORKSPACE_LIB="$(dirname "$0")/../lib"
. "$WORKSPACE_LIB/common.sh"
. "$WORKSPACE_LIB/db.sh"

_path_has_symlink_component() {
  _linked_path="$1"
  while [ "$_linked_path" != "." ] && [ "$_linked_path" != "/" ]; do
    [ -L "$_linked_path" ] && return 0
    _linked_parent=$(dirname -- "$_linked_path")
    [ "$_linked_parent" != "$_linked_path" ] || break
    _linked_path="$_linked_parent"
  done
  return 1
}

_finish_atomic_write() {
  _finish_temporary="$1"
  _finish_destination="$2"
  _finish_mode="$3"

  if ! chmod "$_finish_mode" "$_finish_temporary"; then
    rm -f "$_finish_temporary"
    return 1
  fi
  if [ -f "$_finish_destination" ] && cmp -s "$_finish_temporary" "$_finish_destination"; then
    rm -f "$_finish_temporary"
    return 0
  fi
  if ! mv -f "$_finish_temporary" "$_finish_destination"; then
    rm -f "$_finish_temporary"
    return 1
  fi
}

_atomic_write() {
  _write_destination="$1"
  _write_mode="$2"
  _write_directory=$(dirname -- "$_write_destination")

  if _path_has_symlink_component "$_write_destination"; then
    err "Refusing to write through linked path: $_write_destination"
    return 1
  fi

  mkdir -p "$_write_directory"
  _write_temporary=$(mktemp "$_write_directory/.workspace-init.XXXXXX") || return 1
  if ! cat > "$_write_temporary"; then
    rm -f "$_write_temporary"
    return 1
  fi
  _finish_atomic_write "$_write_temporary" "$_write_destination" "$_write_mode"
}

_linked_provider_config() {
  _provider_file="$1"
  if _path_has_symlink_component "$_provider_file"; then
    warn "$_provider_file is linked — leaving it unchanged"
    return 0
  fi
  return 1
}

_use_project_workspace_entrypoint() {
  _entrypoint_file="$1"
  [ -f "$_entrypoint_file" ] || return 0
  _entrypoint_directory=$(dirname -- "$_entrypoint_file")
  _entrypoint_temporary=$(mktemp "$_entrypoint_directory/.workspace-init.XXXXXX") || return 1
  sed -e 's#"workspace bootstrap"#"bin/workspace bootstrap"#g' \
      -e 's#"workspace run"#"bin/workspace run"#g' \
      -e 's#"workspace archive"#"bin/workspace archive"#g' \
      -e 's#"workspace info"#"bin/workspace info"#g' \
      -e 's#"workspace prune --deferred"#"bin/workspace prune --deferred"#g' \
      -e "s#'workspace bootstrap'#'bin/workspace bootstrap'#g" \
      -e "s#'workspace run'#'bin/workspace run'#g" \
      -e "s#'workspace archive'#'bin/workspace archive'#g" \
      -e "s#'workspace info'#'bin/workspace info'#g" \
      -e "s#'workspace prune --deferred'#'bin/workspace prune --deferred'#g" \
      "$_entrypoint_file" > "$_entrypoint_temporary"
  _finish_atomic_write "$_entrypoint_temporary" "$_entrypoint_file" 644
}

_ensure_codex_info_action() {
  _codex_environment="$1"
  grep -Eq "command = [\"']bin/workspace info[\"']" "$_codex_environment" && return 0
  grep -Eq "(script|command) = [\"']bin/workspace (bootstrap|run|archive)[\"']" "$_codex_environment" || return 0

  _codex_directory=$(dirname -- "$_codex_environment")
  _codex_temporary=$(mktemp "$_codex_directory/.workspace-init.XXXXXX") || return 1
  cat "$_codex_environment" > "$_codex_temporary"
  cat >> "$_codex_temporary" <<'EOF'

[[actions]]
name = "Workspace info"
icon = "tool"
command = "bin/workspace info"
EOF
  _finish_atomic_write "$_codex_temporary" "$_codex_environment" 644
}

# Current Codex runs cleanup inside the disposable worktree, but unlike setup
# it does not export CODEX_WORKTREE_PATH. Prefer the variable when a Codex
# version supplies it; otherwise accept the current checkout only when Git
# proves it is a linked worktree. Paths locate the checkout only. Archive still
# resolves its stable database identity from provider state, markers, hooks,
# and Git metadata.
_CODEX_CLEANUP_TOML_LINE_LEGACY_PATH_REQUIRED='script = "if [ -z \"${CODEX_WORKTREE_PATH:-}\" ]; then echo \"Workspace cleanup: CODEX_WORKTREE_PATH is not set\" >&2; exit 1; fi; if [ ! -d \"$CODEX_WORKTREE_PATH\" ]; then echo \"Workspace cleanup: CODEX_WORKTREE_PATH is not a directory: $CODEX_WORKTREE_PATH\" >&2; exit 1; fi; cd \"$CODEX_WORKTREE_PATH\" || exit 1; if [ ! -x bin/workspace ]; then echo \"Workspace cleanup: bin/workspace is missing or not executable in $CODEX_WORKTREE_PATH\" >&2; exit 1; fi; exec bin/workspace archive"'
_CODEX_CLEANUP_TOML_LINE='script = "if [ -n \"${CODEX_WORKTREE_PATH:-}\" ]; then workspace_cleanup_path=$CODEX_WORKTREE_PATH; else workspace_cleanup_path=$(git rev-parse --show-toplevel 2>/dev/null) || { echo \"Workspace cleanup: CODEX_WORKTREE_PATH is not set and the current directory is not a Git worktree\" >&2; exit 1; }; if [ ! -f \"$workspace_cleanup_path/.git\" ]; then echo \"Workspace cleanup: CODEX_WORKTREE_PATH is not set and cleanup is not running inside a linked Git worktree: $workspace_cleanup_path\" >&2; exit 1; fi; fi; if [ ! -d \"$workspace_cleanup_path\" ]; then echo \"Workspace cleanup: worktree path is not a directory: $workspace_cleanup_path\" >&2; exit 1; fi; cd \"$workspace_cleanup_path\" || exit 1; if [ ! -x bin/workspace ]; then echo \"Workspace cleanup: bin/workspace is missing or not executable in $workspace_cleanup_path\" >&2; exit 1; fi; exec bin/workspace archive"'

_codex_environment_is_workspace_managed() {
  _managed_codex_environment="$1"
  grep -Eq "(script|command) = [\"'](bin/)?workspace (bootstrap|run|info|archive)[\"']" "$_managed_codex_environment"
}

_codex_cleanup_is_configured() {
  _configured_codex_environment="$1"
  ruby -e '
    cleanup_key = lambda do |value|
      ["cleanup", %q{"cleanup"}, 39.chr + "cleanup" + 39.chr].any? do |key|
        next false unless value.start_with?(key)

        remainder = value[key.length..].lstrip
        remainder.empty? || remainder.start_with?(".")
      end
    end

    inside_table = false
    File.foreach(ARGV.fetch(0)) do |line|
      value = line.split("#", 2).first.strip
      if value.start_with?("[") && value.end_with?("]")
        unless value.start_with?("[[") || value[-2, 2] == "]]"
          table_name = value[1...-1].strip
          exit 0 if cleanup_key.call(table_name)
        end
        inside_table = true
        next
      end

      root_key = value.split("=", 2).first.to_s.strip
      exit 0 if !inside_table && cleanup_key.call(root_key)
    end
    exit 1
  ' "$_configured_codex_environment"
}

_upgrade_codex_cleanup_table() {
  _cleanup_codex_environment="$1"
  _cleanup_codex_directory=$(dirname -- "$_cleanup_codex_environment")
  _cleanup_codex_temporary=$(mktemp "$_cleanup_codex_directory/.workspace-init.XXXXXX") || return 1

  if ! CODEX_CLEANUP_TOML_LINE="$_CODEX_CLEANUP_TOML_LINE" \
    CODEX_CLEANUP_TOML_LINE_LEGACY_PATH_REQUIRED="$_CODEX_CLEANUP_TOML_LINE_LEGACY_PATH_REQUIRED" awk '
    /^[[:space:]]*\[[[:space:]]*(cleanup|"cleanup"|\047cleanup\047)[[:space:]]*\][[:space:]]*(#.*)?$/ {
      inside_cleanup = 1
      print
      next
    }
    inside_cleanup && /^[[:space:]]*\[/ {
      inside_cleanup = 0
    }
    inside_cleanup && /^[[:space:]]*script[[:space:]]*=/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      legacy_path_required = ENVIRON["CODEX_CLEANUP_TOML_LINE_LEGACY_PATH_REQUIRED"]
      if (line == legacy_path_required ||
          (index(line, legacy_path_required) == 1 && substr(line, length(legacy_path_required) + 1) ~ /^[[:space:]]*#/)) {
        print ENVIRON["CODEX_CLEANUP_TOML_LINE"]
        next
      }
      value = $0
      sub(/^[[:space:]]*script[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value == "\"bin/workspace archive\"" || value == "\047bin/workspace archive\047" ||
          value ~ /^\"bin\/workspace archive\"[[:space:]]*#/ ||
          value ~ /^\047bin\/workspace archive\047[[:space:]]*#/) {
        print ENVIRON["CODEX_CLEANUP_TOML_LINE"]
        next
      }
    }
    { print }
  ' "$_cleanup_codex_environment" > "$_cleanup_codex_temporary"; then
    rm -f "$_cleanup_codex_temporary"
    return 1
  fi

  _finish_atomic_write "$_cleanup_codex_temporary" "$_cleanup_codex_environment" 644
}

_ensure_codex_cleanup() {
  _cleanup_codex_environment="$1"

  # Any explicit cleanup is a public project contract. Only replace the exact
  # historical Workspace archive default; inline/platform/custom values stay
  # byte-for-byte unchanged.
  if _codex_cleanup_is_configured "$_cleanup_codex_environment"; then
    _upgrade_codex_cleanup_table "$_cleanup_codex_environment"
    return
  fi

  _codex_environment_is_workspace_managed "$_cleanup_codex_environment" || return 0

  _cleanup_codex_directory=$(dirname -- "$_cleanup_codex_environment")
  _cleanup_codex_temporary=$(mktemp "$_cleanup_codex_directory/.workspace-init.XXXXXX") || return 1
  if ! cat "$_cleanup_codex_environment" > "$_cleanup_codex_temporary"; then
    rm -f "$_cleanup_codex_temporary"
    return 1
  fi
  [ -z "$(tail -c1 "$_cleanup_codex_environment" 2>/dev/null)" ] || printf '\n' >> "$_cleanup_codex_temporary"
  printf '\n[cleanup]\n%s\n' "$_CODEX_CLEANUP_TOML_LINE" >> "$_cleanup_codex_temporary"
  _finish_atomic_write "$_cleanup_codex_temporary" "$_cleanup_codex_environment" 644
}

# Convert a legacy conductor.json (in the current directory) into the body of
# .conductor/settings.toml, printed on stdout. Legacy conductor.json is a closed,
# documented format with exactly three fields, which map to new names that the
# repo schema (additionalProperties: false) requires:
#
#   scripts.{setup,run,archive} → scripts.{setup,run,archive}  (unchanged)
#   runScriptMode               → scripts.run_mode
#   enterpriseDataPrivacy       → enterprise_data_privacy
#
# Uses Ruby so JSON string escaping survives. Fills the default workspace scripts
# only when none are present. Exits non-zero (printing nothing) when conductor.json
# is missing, malformed, or carries a field outside that documented set, so the
# caller can leave the original in place rather than emit schema-invalid output.
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

    data = JSON.parse(File.read("conductor.json"))
    raise "not an object" unless Hash === data
    data.each_key { |k| raise "unknown field: #{k}" unless ["$schema", "scripts", "runScriptMode", "enterpriseDataPrivacy"].include?(k) }

    scripts = data.fetch("scripts", {})
    raise "scripts not an object" unless Hash === scripts
    scripts.each do |k, v|
      raise "unknown script: #{k}" unless ["setup", "run", "archive"].include?(k)
      raise "non-string script: #{k}" unless String === v
    end

    out = []
    out << esc("$schema") + " = " + esc("https://conductor.build/schemas/settings.repo.schema.json")

    if data.key?("enterpriseDataPrivacy")
      v = data["enterpriseDataPrivacy"]
      raise "enterpriseDataPrivacy not a boolean" unless v == true || v == false
      out << "enterprise_data_privacy = #{v}"
    end

    out << ""
    out << "[scripts]"
    present = ["setup", "run", "archive"].select { |k| scripts.key?(k) }
    if present.empty?
      out << "setup = " + esc("bin/workspace bootstrap")
      out << "run = " + esc("bin/workspace run")
      out << "archive = " + esc("bin/workspace archive")
    else
      present.each do |k|
        value = scripts[k]
        value = "bin/workspace bootstrap" if k == "setup" && value == "workspace bootstrap"
        value = "bin/workspace run" if k == "run" && value == "workspace run"
        value = "bin/workspace archive" if k == "archive" && value == "workspace archive"
        out << "#{k} = #{esc(value)}"
      end
    end
    if data.key?("runScriptMode")
      v = data["runScriptMode"]
      raise "runScriptMode not a string" unless String === v
      out << "run_mode = #{esc(v)}"
    end

    print out.join("\n") + "\n"
  '
}

header "Initializing workspace support"

# Refuse ambiguous or unsafe core destinations before init mutates the project.
if [ -L bin ]; then
  err "Refusing to create bin/workspace through linked directory: bin"
  exit 1
elif { [ -e bin/workspace ] || [ -L bin/workspace ]; } && \
     ! { [ -f bin/workspace ] && grep -q '^# Generated by workspace init\.$' bin/workspace 2>/dev/null; }; then
  err "bin/workspace already exists and is not a Workspace-generated shim."
  err "Remove or rename bin/workspace, then run workspace init again."
  exit 1
fi
if [ -L .workspace-version ]; then
  err "Refusing to replace linked version contract: .workspace-version"
  exit 1
fi
if [ -L .gitignore ]; then
  err "Refusing to update linked file: .gitignore"
  exit 1
fi

# ── Patch database.yml ──────────────────────────────────────────

patch_database_yml

# ── Create the project-local entrypoint and version contract ─────

mkdir -p bin
if [ ! -f bin/workspace ] || grep -q '^# Generated by workspace init\.$' bin/workspace 2>/dev/null; then
  _atomic_write bin/workspace 755 <<'EOF'
#!/bin/sh
# Generated by workspace init.
# Keeps managed-provider shells independent of user dotfiles and PATH setup.
set -e

_workspace_self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
_workspace_self="$_workspace_self_dir/$(basename -- "$0")"
_workspace_cli=""
_workspace_canonical_cli=""

if _workspace_path_cli=$(command -v workspace 2>/dev/null); then
  _workspace_path_dir=$(CDPATH= cd -- "$(dirname -- "$_workspace_path_cli")" 2>/dev/null && pwd -P || true)
  _workspace_path_abs="$_workspace_path_dir/$(basename -- "$_workspace_path_cli")"
  if [ -n "$_workspace_path_abs" ] && [ "$_workspace_path_abs" != "$_workspace_self" ]; then
    _workspace_cli="$_workspace_path_abs"
  fi
fi

_workspace_install_home="${WORKSPACE_HOME:-${HOME:-}/.workspace}"
if [ -x "$_workspace_install_home/bin/workspace" ]; then
  _workspace_canonical_cli="$_workspace_install_home/bin/workspace"
  [ -n "$_workspace_cli" ] || _workspace_cli="$_workspace_canonical_cli"
fi

if [ -z "$_workspace_cli" ]; then
  echo "Workspace is not installed." >&2
  echo "Install it once, then rerun this command:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/jnunemaker/workspace/main/install.sh | bash" >&2
  exit 127
fi

_workspace_required_file="$_workspace_self_dir/../.workspace-version"
if [ "${1:-}" != "update" ] && [ -s "$_workspace_required_file" ]; then
  _workspace_required=$(cat "$_workspace_required_file")
  _workspace_install_root=$(CDPATH= cd -- "$(dirname -- "$_workspace_cli")/.." && pwd -P)
  _workspace_revision_ok=false
  if git -C "$_workspace_install_root" merge-base --is-ancestor "$_workspace_required" HEAD 2>/dev/null; then
    _workspace_revision_ok=true
  elif [ -n "$_workspace_canonical_cli" ] && [ "$_workspace_canonical_cli" != "$_workspace_cli" ]; then
    _workspace_canonical_root=$(CDPATH= cd -- "$(dirname -- "$_workspace_canonical_cli")/.." && pwd -P)
    if git -C "$_workspace_canonical_root" merge-base --is-ancestor "$_workspace_required" HEAD 2>/dev/null; then
      _workspace_cli="$_workspace_canonical_cli"
      _workspace_install_root="$_workspace_canonical_root"
      _workspace_revision_ok=true
    fi
  fi
  if [ "$_workspace_revision_ok" != true ]; then
    _workspace_update_cli="$_workspace_cli"
    [ -z "$_workspace_canonical_cli" ] || _workspace_update_cli="$_workspace_canonical_cli"
    echo "Workspace is older than this repository requires." >&2
    echo "Update it with this exact command:" >&2
    echo "  $_workspace_update_cli update" >&2
    exit 1
  fi
fi

_workspace_install_root=$(CDPATH= cd -- "$(dirname -- "$_workspace_cli")/.." && pwd -P)
export WORKSPACE_HOME="$_workspace_install_root"
exec "$_workspace_cli" "$@"
EOF
  ok "Created bin/workspace"
fi

_workspace_install_root=$(CDPATH= cd -- "$WORKSPACE_LIB/.." && pwd -P)
_workspace_required_version=$(git -C "$_workspace_install_root" rev-parse HEAD 2>/dev/null || true)
if [ -n "$_workspace_required_version" ]; then
  _workspace_existing_version=""
  [ ! -s .workspace-version ] || _workspace_existing_version=$(cat .workspace-version)
  if [ -z "$_workspace_existing_version" ] || \
     git -C "$_workspace_install_root" merge-base --is-ancestor "$_workspace_existing_version" "$_workspace_required_version" 2>/dev/null; then
    _atomic_write .workspace-version 644 <<EOF
$_workspace_required_version
EOF
    ok "Updated .workspace-version"
  else
    warn ".workspace-version requires a revision newer than this install — leaving it unchanged"
  fi
else
  warn "Could not determine the installed Workspace revision; .workspace-version was not changed"
fi

# ── Create .conductor/settings.toml ─────────────────────────────

if _linked_provider_config .conductor/settings.toml; then
  :
elif [ -f .conductor/settings.toml ]; then
  _use_project_workspace_entrypoint .conductor/settings.toml
  step ".conductor/settings.toml already exists (Workspace commands updated)"
elif [ -f conductor.json ]; then
  # Conductor moved repo config from conductor.json to .conductor/settings.toml.
  # Convert the whole file, and only drop the legacy one once it has migrated.
  if _toml=$(_conductor_json_to_toml 2>/dev/null) && [ -n "$_toml" ]; then
    mkdir -p .conductor
    _atomic_write .conductor/settings.toml 644 <<EOF
$_toml
EOF
    rm -f conductor.json
    ok "Migrated conductor.json → .conductor/settings.toml"
  else
    warn "Couldn't safely migrate conductor.json — left it in place."
    warn "Copy its settings into .conductor/settings.toml by hand, then delete it."
  fi
else
  _atomic_write .conductor/settings.toml 644 <<'EOF'
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

[scripts]
setup = "bin/workspace bootstrap"
run = "bin/workspace run"
archive = "bin/workspace archive"
EOF
  ok "Created .conductor/settings.toml"
fi

# ── Create .superconductor/config.json ──────────────────────────

if _linked_provider_config .superconductor/config.json; then
  :
elif [ -f .superconductor/config.json ]; then
  _use_project_workspace_entrypoint .superconductor/config.json
  step ".superconductor/config.json already exists (Workspace commands updated)"
else
  _atomic_write .superconductor/config.json 644 <<'EOF'
{
  "setup": ["bin/workspace bootstrap"],
  "run": ["bin/workspace run"]
}
EOF
  ok "Created .superconductor/config.json"
fi

# ── Create .superset/config.json ────────────────────────────────

if _linked_provider_config .superset/config.json; then
  :
elif [ -f .superset/config.json ]; then
  _use_project_workspace_entrypoint .superset/config.json
  step ".superset/config.json already exists (Workspace commands updated)"
else
  _atomic_write .superset/config.json 644 <<'EOF'
{
  "setup": ["bin/workspace bootstrap"],
  "teardown": ["bin/workspace archive"]
}
EOF
  ok "Created .superset/config.json"
fi

# ── Create Codex local environment ─────────────────────────────────────────

if _linked_provider_config .codex/environments/environment.toml; then
  :
elif [ -f .codex/environments/environment.toml ]; then
  _use_project_workspace_entrypoint .codex/environments/environment.toml
  _ensure_codex_info_action .codex/environments/environment.toml
  _ensure_codex_cleanup .codex/environments/environment.toml
  step ".codex/environments/environment.toml already exists (Workspace commands updated)"
else
  _codex_environment_name=$(basename "$(pwd)" \
    | tr -cs 'a-zA-Z0-9._-' '-' \
    | sed 's/^-*//;s/-*$//')
  [ -n "$_codex_environment_name" ] || _codex_environment_name="workspace"
  _atomic_write .codex/environments/environment.toml 644 <<EOF
# THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY
version = 1
name = "$_codex_environment_name"

[setup]
script = "bin/workspace bootstrap"

[cleanup]
$_CODEX_CLEANUP_TOML_LINE

[[actions]]
name = "Run"
icon = "run"
command = "bin/workspace run"

[[actions]]
name = "Workspace info"
icon = "tool"
command = "bin/workspace info"

[[actions]]
name = "Archive workspace"
icon = "tool"
command = "bin/workspace archive"
EOF
  ok "Created .codex/environments/environment.toml"
fi

# Native Codex cleanup is the normal teardown path. SessionEnd remains recovery
# for older clients, interrupted cleanup, forced worktree deletion, and app
# shutdown: deferred prune acts only after Git confirms the worktree is gone.
if _linked_provider_config .codex/hooks.json; then
  :
elif [ -f .codex/hooks.json ]; then
  _use_project_workspace_entrypoint .codex/hooks.json
  step ".codex/hooks.json already exists (Workspace commands updated)"
else
  _atomic_write .codex/hooks.json 644 <<'EOF'
{
  "description": "Recover resources when native Codex worktree cleanup did not finish.",
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bin/workspace prune --deferred",
            "timeout": 5,
            "statusMessage": "Scheduling workspace cleanup"
          }
        ]
      }
    ]
  }
}
EOF
  ok "Created .codex/hooks.json"
fi

# ── Add .workspace to .gitignore ────────────────────────────────

if [ -f .gitignore ] && grep -qxF '.workspace' .gitignore; then
  step ".workspace already in .gitignore"
elif [ -f .gitignore ]; then
  _gitignore_temporary=$(mktemp "./.workspace-init.XXXXXX")
  cat .gitignore > "$_gitignore_temporary"
  [ -z "$(tail -c1 .gitignore 2>/dev/null)" ] || printf '\n' >> "$_gitignore_temporary"
  printf '.workspace\n' >> "$_gitignore_temporary"
  _finish_atomic_write "$_gitignore_temporary" .gitignore 644
  ok "Added .workspace to .gitignore"
else
  _atomic_write .gitignore 644 <<'EOF'
.workspace
EOF
  ok "Created .gitignore with .workspace"
fi

printf "\n${_green}  ✓${_reset} ${_bold}Project is now workspace-ready${_reset}\n"
