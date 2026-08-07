#!/bin/sh
# Tests for workspace info output.

cd "$(dirname "$0")"
. ./test_helper.sh

output_has() {
  printf '%s\n' "$1" | grep -q "$2"
}

help_output=$(WORKSPACE_HOME="$WORKSPACE_HOME" "$WORKSPACE_HOME/bin/workspace" --help)
assert_true "CLI help lists info command" output_has "$help_output" '^  info '

app_dir=$(create_fake_app "info-conductor")
root_dir=$(create_fake_root "info-conductor")
cd "$app_dir"
cat > Procfile.dev <<'EOF'
caddy: caddy run
vite: bin/vite dev
EOF

output=$(CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="feature-info" CONDUCTOR_PORT=4100 sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "info reports Conductor provider" output_has "$output" '^Provider: conductor$'
assert_true "info reports workspace name" output_has "$output" '^Workspace: feature-info$'
assert_true "info reports provider-derived identity source" output_has "$output" '^Identity source: derived$'
assert_true "info reports root" output_has "$output" "^Root: $root_dir$"
assert_true "info reports database suffix" output_has "$output" '^Database suffix: _feature-info$'
assert_true "info reports Caddy URL" output_has "$output" '^URL: https://info-conductor.localhost:4100$'
assert_true "info reports allocated port block" output_has "$output" '^Ports: 4100-4109$'
assert_true "info reports Rails port" output_has "$output" '^  Rails: 4101$'
assert_true "info reports Caddy admin port" output_has "$output" '^  Caddy admin: 4102$'
assert_true "info reports Vite port" output_has "$output" '^  Vite: 4103$'

printf '%s' "existing-database" > .conductor-workspace
printf '%s' "wrong-workspace" > .workspace
output=$(SUPERSET_ROOT_PATH="$root_dir" SUPERSET_WORKSPACE_NAME="renamed-provider" SUPERSET_PORT=4150 sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "info trusts existing Conductor marker" output_has "$output" '^Workspace: existing-database$'
assert_true "info reports Conductor marker source" output_has "$output" '^Identity source: .conductor-workspace$'
assert_true "info uses resolved database suffix" output_has "$output" '^Database suffix: _existing-database$'

app_dir=$(create_fake_app "info-default")
cd "$app_dir"
output=$(WORKSPACE_APP_URL="https://app.example.test" sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "default info reports default provider" output_has "$output" '^Provider: default$'
assert_true "default info reports default workspace" output_has "$output" '^Workspace: default$'
assert_true "default info has no suffix" output_has "$output" '^Database suffix: (none)$'
assert_true "info honors explicit URL" output_has "$output" '^URL: https://app.example.test$'
assert_true "default info reports standard block" output_has "$output" '^Ports: 3000-3009$'

printf 'WORKSPACE_APP_URL=https://dotenv.example.test\n' > .env
output=$(sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "info loads application URL from dotenv like run" output_has "$output" '^URL: https://dotenv.example.test$'

app_dir=$(create_fake_app "info-invalid-name")
root_dir=$(create_fake_root "info-invalid-name")
cd "$app_dir"
invalid_output="$TEST_TMP/info-invalid-name.out"
if SUPERSET_ROOT_PATH="$root_dir" SUPERSET_WORKSPACE_NAME="!!!" sh "$WORKSPACE_HOME/lib/info.sh" >"$invalid_output" 2>&1; then
  invalid_status=0
else
  invalid_status=$?
fi
assert_equal "info rejects a workspace name that sanitizes to empty" "1" "$invalid_status"
assert_true "invalid workspace name explains suffix safety" grep -q 'Workspace name cannot produce a safe isolated database suffix' "$invalid_output"

app_dir=$(create_fake_app "info-invalid-port")
root_dir=$(create_fake_root "info-invalid-port")
cd "$app_dir"
invalid_output="$TEST_TMP/info-invalid-port.out"
if CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="feature-info" CONDUCTOR_PORT="not-a-port" sh "$WORKSPACE_HOME/lib/info.sh" >"$invalid_output" 2>&1; then
  invalid_status=0
else
  invalid_status=$?
fi
assert_equal "info rejects a nonnumeric provider port" "1" "$invalid_status"
assert_true "invalid provider port identifies the value" grep -q "Port must be a number, got 'not-a-port'" "$invalid_output"

app_dir=$(create_fake_app "info-vite")
root_dir=$(create_fake_root "info-vite")
cd "$app_dir"
cat > Procfile.dev <<'EOF'
vite: bin/vite dev
web: bin/rails server
EOF
output=$(CONDUCTOR_ROOT_PATH="$root_dir" CONDUCTOR_WORKSPACE_NAME="feature-vite" CONDUCTOR_PORT=4200 sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "non-Caddy Vite info reports HTTP app URL" output_has "$output" '^URL: http://localhost:4200$'
assert_true "non-Caddy Vite info reports app port" output_has "$output" '^  App: 4200$'
assert_true "non-Caddy Vite info assigns the next port to Vite" output_has "$output" '^  Vite: 4201$'
assert_false "non-Caddy Vite info omits Rails proxy port" output_has "$output" '^  Rails:'
assert_false "non-Caddy Vite info omits Caddy admin port" output_has "$output" '^  Caddy admin:'

git_root="$TEST_TMP/info-git-root"
codex_home="$TEST_TMP/info-codex"
git_worktree="$codex_home/worktrees/info-git"
mkdir -p "$git_root" "$codex_home/worktrees"
git -C "$git_root" init -q
git -C "$git_root" config user.email "workspace-tests@example.com"
git -C "$git_root" config user.name "Workspace Tests"
printf 'root\n' > "$git_root/README.md"
git -C "$git_root" add README.md
git -C "$git_root" commit -qm "initial"
git -C "$git_root" worktree add -q --detach "$git_worktree"
git_root=$(cd "$git_root" && pwd -P)
cd "$git_worktree"
output=$(CODEX_HOME="$codex_home" sh "$WORKSPACE_HOME/lib/info.sh")
assert_true "Git worktree info uses the generic provider label" output_has "$output" '^Provider: git$'
assert_true "Git worktree info reports the main checkout as root" output_has "$output" "^Root: $git_root$"

report "workspace info"
