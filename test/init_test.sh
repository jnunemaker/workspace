#!/bin/sh
# Tests for lib/init.sh — workspace init command.

cd "$(dirname "$0")"
. ./test_helper.sh

run_init() {
  sh "$WORKSPACE_HOME/lib/init.sh" >/dev/null 2>&1
}

# ── init: creates .conductor/settings.toml ──────────────────────

app_dir=$(create_fake_app "init-conductor")
cd "$app_dir"
run_init

assert_true ".conductor/settings.toml created" [ -f .conductor/settings.toml ]
assert_true "settings.toml has schema" grep -q 'settings.repo.schema.json' .conductor/settings.toml
assert_true "settings.toml has scripts table" grep -q '\[scripts\]' .conductor/settings.toml
assert_true "settings.toml has shim setup script" grep -q 'setup = "bin/workspace bootstrap"' .conductor/settings.toml
assert_true "settings.toml has shim run script" grep -q 'run = "bin/workspace run"' .conductor/settings.toml
assert_true "settings.toml has shim archive script" grep -q 'archive = "bin/workspace archive"' .conductor/settings.toml

# ── init: creates .superconductor/config.json ───────────────────

assert_true ".superconductor/config.json created" [ -f .superconductor/config.json ]
assert_true "superconductor config has shim setup script" grep -q 'bin/workspace bootstrap' .superconductor/config.json
assert_true "superconductor config has shim run script" grep -q 'bin/workspace run' .superconductor/config.json

# ── init: creates .superset/config.json ─────────────────────────

assert_true ".superset/config.json created" [ -f .superset/config.json ]
assert_true "superset config has shim setup script" grep -q 'bin/workspace bootstrap' .superset/config.json
assert_true "superset config has shim teardown script" grep -q 'bin/workspace archive' .superset/config.json

# ── Codex local environment and lifecycle hook ────────────────────────

assert_true "codex environment created" [ -f .codex/environments/environment.toml ]
assert_true "codex environment runs shim bootstrap" grep -q 'script = "bin/workspace bootstrap"' .codex/environments/environment.toml
assert_true "codex environment has shim run action" grep -q 'command = "bin/workspace run"' .codex/environments/environment.toml
assert_true "codex environment has shim info action" grep -q 'command = "bin/workspace info"' .codex/environments/environment.toml
assert_true "codex environment has shim archive action" grep -q 'command = "bin/workspace archive"' .codex/environments/environment.toml
assert_true "codex hooks created" [ -f .codex/hooks.json ]
assert_true "codex hooks schedule shim prune" grep -q 'bin/workspace prune --deferred' .codex/hooks.json
assert_true "codex hooks contain valid JSON" ruby -rjson -e 'JSON.parse(File.read(".codex/hooks.json"))'

# ── init: creates the entrypoint and no optional hook scaffolds ──

assert_true "bin/workspace created" [ -f bin/workspace ]
assert_true "bin/workspace is executable" [ -x bin/workspace ]
assert_true "minimum version contract created" [ -s .workspace-version ]
assert_false "optional seed hook is not scaffolded" [ -e bin/workspace-seed ]
assert_false "optional setup hook is not scaffolded" [ -e bin/workspace-setup-hook ]

future_revision=ffffffffffffffffffffffffffffffffffffffff
printf '%s\n' "$future_revision" > .workspace-version
version_output="$TEST_TMP/init-version-downgrade.out"
assert_true "global init preserves an unrecognized newer version contract" sh "$WORKSPACE_HOME/lib/init.sh" >"$version_output" 2>&1
assert_equal "newer minimum revision is not downgraded" "$future_revision" "$(cat .workspace-version)"
assert_true "preserved newer revision is explained" grep -q 'newer than this install.*leaving it unchanged' "$version_output"

# ── init: doesn't overwrite existing bin/workspace-seed ─────────

app_dir=$(create_fake_app "init-seed-exists")
cd "$app_dir"
cat > bin/workspace-seed <<'EOF'
#!/bin/sh
bin/rails db:fixtures:load
EOF
chmod +x bin/workspace-seed

run_init
assert_true "bin/workspace-seed not overwritten" grep -q 'db:fixtures:load' bin/workspace-seed
assert_false "no scaffold comments added" grep -q 'plan:seed' bin/workspace-seed

# ── init: migrates a legacy conductor.json ──────────────────────

app_dir=$(create_fake_app "init-migrate-conductor")
cd "$app_dir"
cat > conductor.json <<'EOF'
{
  "scripts": {
    "setup": "bin/legacy-setup",
    "run": "bin/legacy-run",
    "archive": "bin/legacy-archive"
  }
}
EOF

run_init

assert_false "legacy conductor.json removed" [ -f conductor.json ]
assert_true "settings.toml created from migration" [ -f .conductor/settings.toml ]
assert_true "migration keeps schema" grep -q 'settings.repo.schema.json' .conductor/settings.toml
assert_true "migration has scripts table" grep -q '\[scripts\]' .conductor/settings.toml
assert_true "migrated setup script" grep -q 'setup = "bin/legacy-setup"' .conductor/settings.toml
assert_true "migrated run script" grep -q 'run = "bin/legacy-run"' .conductor/settings.toml
assert_true "migrated archive script" grep -q 'archive = "bin/legacy-archive"' .conductor/settings.toml

# Legacy Conductor defaults should follow the same project-local entrypoint
# migration as existing provider configs, while custom values remain untouched.
app_dir=$(create_fake_app "init-migrate-conductor-workspace-defaults")
cd "$app_dir"
cat > conductor.json <<'EOF'
{
  "scripts": {
    "setup": "workspace bootstrap",
    "run": "bin/custom-run",
    "archive": "workspace archive"
  }
}
EOF

run_init

assert_true "legacy Conductor setup default uses shim" grep -q 'setup = "bin/workspace bootstrap"' .conductor/settings.toml
assert_true "legacy Conductor custom run remains unchanged" grep -q 'run = "bin/custom-run"' .conductor/settings.toml
assert_true "legacy Conductor archive default uses shim" grep -q 'archive = "bin/workspace archive"' .conductor/settings.toml

# ── init: migrating a scriptless conductor.json falls back to defaults ──

app_dir=$(create_fake_app "init-migrate-empty")
cd "$app_dir"
cat > conductor.json <<'EOF'
{}
EOF

run_init

assert_false "scriptless conductor.json removed" [ -f conductor.json ]
assert_true "fallback settings.toml created" [ -f .conductor/settings.toml ]
assert_true "fallback uses shim setup script" grep -q 'setup = "bin/workspace bootstrap"' .conductor/settings.toml
assert_true "fallback uses shim run script" grep -q 'run = "bin/workspace run"' .conductor/settings.toml
assert_true "fallback uses shim archive script" grep -q 'archive = "bin/workspace archive"' .conductor/settings.toml

# ── init: maps legacy settings to their new schema names ────────
# The repo schema is additionalProperties:false, so legacy field names must be
# translated (not passed through verbatim) or Conductor rejects them.

app_dir=$(create_fake_app "init-migrate-settings")
cd "$app_dir"
cat > conductor.json <<'EOF'
{
  "runScriptMode": "nonconcurrent",
  "enterpriseDataPrivacy": true,
  "scripts": {
    "setup": "bin/legacy-setup"
  }
}
EOF

run_init

assert_false "conductor.json removed after settings migration" [ -f conductor.json ]
assert_true "runScriptMode mapped to scripts.run_mode" grep -q 'run_mode = "nonconcurrent"' .conductor/settings.toml
assert_true "enterpriseDataPrivacy mapped to enterprise_data_privacy" grep -q 'enterprise_data_privacy = true' .conductor/settings.toml
assert_true "scripts still migrated alongside settings" grep -q 'setup = "bin/legacy-setup"' .conductor/settings.toml
assert_false "legacy camelCase key not written verbatim" grep -q 'runScriptMode' .conductor/settings.toml
assert_false "legacy privacy key not written verbatim" grep -q 'enterpriseDataPrivacy' .conductor/settings.toml
assert_true "top-level scalar precedes the [scripts] table (valid TOML)" awk '/^\[/ && !t { t = NR } /^enterprise_data_privacy/ { s = NR } END { exit !(s && t && s < t) }' .conductor/settings.toml

# ── init: refuses to migrate an unknown legacy field ────────────
# A field outside the documented legacy set could map to anything (or nothing);
# leave conductor.json alone rather than guess or drop it.

app_dir=$(create_fake_app "init-migrate-unknown-field")
cd "$app_dir"
cat > conductor.json <<'EOF'
{ "scripts": { "setup": "x" }, "somethingNew": 1 }
EOF

run_init

assert_true "conductor.json with unknown field kept" [ -f conductor.json ]
assert_false "no settings.toml written for unknown field" [ -f .conductor/settings.toml ]

# ── init: migration preserves escaped quotes in script values ────

app_dir=$(create_fake_app "init-migrate-escapes")
cd "$app_dir"
cat > conductor.json <<'EOF'
{
  "scripts": {
    "setup": "bin/rails runner \"puts :ok\""
  }
}
EOF

run_init

assert_false "conductor.json removed after escaped-quote migration" [ -f conductor.json ]
assert_true "escaped quotes preserved verbatim" grep -qF 'setup = "bin/rails runner \"puts :ok\""' .conductor/settings.toml

# ── init: leaves an unconvertible conductor.json in place ────────

app_dir=$(create_fake_app "init-migrate-unsupported")
cd "$app_dir"
cat > conductor.json <<'EOF'
{ "scripts": { "setup": { "too": "deep" } } }
EOF

run_init

assert_true "unconvertible conductor.json kept" [ -f conductor.json ]
assert_false "no settings.toml written on failed migration" [ -f .conductor/settings.toml ]

# ── init: idempotent — doesn't overwrite existing configs ───────

app_dir=$(create_fake_app "init-idempotent")
cd "$app_dir"

mkdir -p .conductor
cat > .conductor/settings.toml <<'EOF'
[scripts]
setup = "bin/custom-setup"
EOF

mkdir -p .superconductor
mkdir -p .codex/environments
cat > .superconductor/config.json <<'EOF'
{
  "setup": ["bin/custom-setup"]
}
EOF
mkdir -p .superset
cat > .superset/config.json <<'EOF'
{
  "setup": ["bin/custom-setup"]
}
EOF
cat > .codex/environments/environment.toml <<'EOF'
version = 1
name = "custom-codex"

[setup]
script = "bin/custom-setup"
EOF
mkdir -p .codex
cat > .codex/hooks.json <<'EOF'
{"hooks":{"SessionEnd":[]}}
EOF

run_init

assert_true "settings.toml not overwritten" grep -q 'custom-setup' .conductor/settings.toml
assert_true "superconductor config not overwritten" grep -q 'custom-setup' .superconductor/config.json
assert_true "superset config not overwritten" grep -q 'custom-setup' .superset/config.json
assert_true "codex environment not overwritten" grep -q 'custom-codex' .codex/environments/environment.toml
assert_false "codex environment default not appended" grep -q 'workspace bootstrap' .codex/environments/environment.toml
assert_false "codex hooks not overwritten" grep -q 'workspace prune' .codex/hooks.json

# ── init: upgrades only known Workspace commands in existing configs ──

app_dir=$(create_fake_app "init-upgrade-entrypoints")
cd "$app_dir"
mkdir -p .conductor .superconductor .superset .codex/environments
cat > .conductor/settings.toml <<'EOF'
[scripts]
setup = "workspace bootstrap"
run = "bin/custom-run"
archive = "workspace archive"
# Preserve example: "workspace bootstrap --custom"
EOF
cat > .superconductor/config.json <<'EOF'
{"setup":["workspace bootstrap"],"run":["workspace run"]}
EOF
cat > .superset/config.json <<'EOF'
{"setup":["workspace bootstrap"],"teardown":["workspace archive"]}
EOF
cat > .codex/environments/environment.toml <<'EOF'
[setup]
script = "workspace bootstrap"
EOF
cat > .codex/hooks.json <<'EOF'
{"command":"workspace prune --deferred"}
EOF

run_init
run_init

assert_true "existing Conductor setup upgraded once" grep -q 'setup = "bin/workspace bootstrap"' .conductor/settings.toml
assert_true "custom Conductor command preserved" grep -q 'run = "bin/custom-run"' .conductor/settings.toml
assert_true "extended Workspace command is treated as custom" grep -q '"workspace bootstrap --custom"' .conductor/settings.toml
assert_false "entrypoint upgrade is idempotent" grep -q 'bin/bin/workspace' .conductor/settings.toml
assert_true "existing Superconductor config upgraded" grep -q 'bin/workspace run' .superconductor/config.json
assert_true "existing Superset config upgraded" grep -q 'bin/workspace archive' .superset/config.json
assert_true "existing Codex environment upgraded" grep -q 'bin/workspace bootstrap' .codex/environments/environment.toml
assert_true "existing Codex environment gains info action" grep -q 'command = "bin/workspace info"' .codex/environments/environment.toml
assert_true "existing Codex hook upgraded" grep -q 'bin/workspace prune --deferred' .codex/hooks.json

# TOML permits literal strings. Upgrade exact single-quoted Workspace commands
# and recognize an existing single-quoted info action without appending another.
app_dir=$(create_fake_app "init-upgrade-single-quoted-toml")
cd "$app_dir"
mkdir -p .conductor .codex/environments
cat > .conductor/settings.toml <<'EOF'
[scripts]
setup = 'workspace bootstrap'
run = 'workspace run'
archive = 'bin/custom-archive'
EOF
cat > .codex/environments/environment.toml <<'EOF'
[setup]
script = 'workspace bootstrap'

[[actions]]
name = 'Workspace info'
command = 'workspace info'
EOF

run_init

assert_true "single-quoted Conductor setup upgraded" grep -q "setup = 'bin/workspace bootstrap'" .conductor/settings.toml
assert_true "single-quoted Conductor run upgraded" grep -q "run = 'bin/workspace run'" .conductor/settings.toml
assert_true "single-quoted custom command preserved" grep -q "archive = 'bin/custom-archive'" .conductor/settings.toml
assert_true "single-quoted Codex setup upgraded" grep -q "script = 'bin/workspace bootstrap'" .codex/environments/environment.toml
assert_true "single-quoted Codex info upgraded" grep -q "command = 'bin/workspace info'" .codex/environments/environment.toml
info_count=$(grep -c 'bin/workspace info' .codex/environments/environment.toml)
assert_equal "single-quoted Codex info action is not duplicated" "1" "$info_count"

# ── init: rejects an unrelated bin/workspace before migration ───

app_dir=$(create_fake_app "init-entrypoint-collision")
cd "$app_dir"
cat > config/database.yml <<'YAML'
development:
  database: collision_development
YAML
cat > bin/workspace <<'EOF'
#!/bin/sh
echo unrelated
EOF
chmod +x bin/workspace
output="$TEST_TMP/init-entrypoint-collision.out"

assert_false "foreign bin/workspace aborts init" sh "$WORKSPACE_HOME/lib/init.sh" >"$output" 2>&1
assert_true "collision message is actionable" grep -q 'Remove or rename bin/workspace' "$output"
assert_true "foreign bin/workspace is preserved" grep -q '^echo unrelated$' bin/workspace
assert_false "collision aborts before version contract" [ -e .workspace-version ]
assert_false "collision aborts before provider config generation" [ -e .conductor/settings.toml ]
assert_false "collision aborts before database patching" grep -q WORKSPACE_DB_SUFFIX config/database.yml

app_dir=$(create_fake_app "init-linked-entrypoint")
cd "$app_dir"
entrypoint_sentinel="$TEST_TMP/init-entrypoint-sentinel"
printf 'sentinel-entrypoint\n' > "$entrypoint_sentinel"
ln -s "$entrypoint_sentinel" bin/workspace
output="$TEST_TMP/init-linked-entrypoint.out"
assert_false "linked bin/workspace aborts init" sh "$WORKSPACE_HOME/lib/init.sh" >"$output" 2>&1
assert_equal "linked bin/workspace target is untouched" "sentinel-entrypoint" "$(cat "$entrypoint_sentinel")"

# ── init: preserves linked configs and resists temp-file symlinks ─

app_dir=$(create_fake_app "init-linked-config")
cd "$app_dir"
mkdir -p .conductor
linked_target="$TEST_TMP/shared-conductor.toml"
printf '[scripts]\nsetup = "workspace bootstrap"\n' > "$linked_target"
ln -s "$linked_target" .conductor/settings.toml
run_init
assert_true "linked provider config remains a symlink" [ -L .conductor/settings.toml ]
assert_true "linked provider target remains unchanged" grep -q 'setup = "workspace bootstrap"' "$linked_target"

app_dir=$(create_fake_app "init-temp-symlink")
cd "$app_dir"
mkdir -p .conductor
printf '[scripts]\nsetup = "workspace bootstrap"\n' > .conductor/settings.toml
temp_sentinel="$TEST_TMP/init-temp-sentinel"
printf 'sentinel\n' > "$temp_sentinel"
ln -s "$temp_sentinel" .conductor/settings.toml.tmp
run_init
assert_equal "predictable temp symlink target is untouched" "sentinel" "$(cat "$temp_sentinel")"
assert_true "regular provider config is still upgraded" grep -q 'bin/workspace bootstrap' .conductor/settings.toml

app_dir=$(create_fake_app "init-version-symlink")
cd "$app_dir"
version_sentinel="$TEST_TMP/init-version-sentinel"
printf 'sentinel-version\n' > "$version_sentinel"
ln -s "$version_sentinel" .workspace-version
output="$TEST_TMP/init-version-symlink.out"
assert_false "linked version contract aborts init" sh "$WORKSPACE_HOME/lib/init.sh" >"$output" 2>&1
assert_equal "linked version target is untouched" "sentinel-version" "$(cat "$version_sentinel")"

app_dir=$(create_fake_app "init-gitignore-symlink")
cd "$app_dir"
gitignore_sentinel="$TEST_TMP/init-gitignore-sentinel"
printf 'sentinel-gitignore\n' > "$gitignore_sentinel"
ln -s "$gitignore_sentinel" .gitignore
output="$TEST_TMP/init-gitignore-symlink.out"
assert_false "linked .gitignore aborts init" sh "$WORKSPACE_HOME/lib/init.sh" >"$output" 2>&1
assert_equal "linked .gitignore target is untouched" "sentinel-gitignore" "$(cat "$gitignore_sentinel")"

# ── init: adds .workspace to .gitignore ─────────────────────────

# Creates .gitignore when missing
app_dir=$(create_fake_app "init-gitignore-missing")
cd "$app_dir"
run_init
assert_true ".gitignore created" [ -f .gitignore ]
assert_true ".gitignore contains .workspace" grep -qxF '.workspace' .gitignore

# Appends to existing .gitignore
app_dir=$(create_fake_app "init-gitignore-existing")
cd "$app_dir"
printf 'node_modules\ntmp/\n' > .gitignore
run_init
assert_true "existing entry preserved" grep -qxF 'node_modules' .gitignore
assert_true ".workspace appended" grep -qxF '.workspace' .gitignore

# Idempotent — doesn't duplicate .workspace
app_dir=$(create_fake_app "init-gitignore-idempotent")
cd "$app_dir"
printf '.workspace\n' > .gitignore
run_init
count=$(grep -cxF '.workspace' .gitignore)
assert_equal ".workspace appears once" "1" "$count"

# Handles .gitignore without trailing newline
app_dir=$(create_fake_app "init-gitignore-no-newline")
cd "$app_dir"
printf 'tmp/' > .gitignore
run_init
assert_true "previous entry intact" grep -qxF 'tmp/' .gitignore
assert_true ".workspace on its own line" grep -qxF '.workspace' .gitignore

# ── init: patches database.yml with WORKSPACE_DB_SUFFIX ─────────

if command -v ruby >/dev/null 2>&1; then
  app_dir=$(create_fake_app "init-db-patch")
  cd "$app_dir"
  cat > config/database.yml <<'YAML'
development:
  database: myapp_development

test:
  database: myapp_test
YAML

  run_init

  assert_true "database.yml patched with WORKSPACE_DB_SUFFIX" grep -q 'WORKSPACE_DB_SUFFIX' config/database.yml
  assert_false "database.yml does not use DEV_ENV_NUMBER" grep -q 'DEV_ENV_NUMBER' config/database.yml
  assert_false "database.yml does not use TEST_ENV_NUMBER" grep -q 'TEST_ENV_NUMBER' config/database.yml
fi

# ── init: skips database.yml patch when missing ─────────────────

app_dir=$(create_fake_app "init-no-db")
cd "$app_dir"
rm -f config/database.yml

run_init
assert_equal "no database.yml → no error" "0" "$?"
assert_false "no database.yml created" [ -f config/database.yml ]

report "init.sh"
