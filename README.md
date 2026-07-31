# workspace

A small CLI for running multiple isolated checkouts of the same app side-by-side — different branches, different databases, different ports — without them stepping on each other.

Inspired by git worktrees: one "root" checkout holds the shared config (`.env`, `.bundle`, `config/master.key`, `storage/`, etc.), and additional workspaces symlink to it and get their own suffixed databases.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jnunemaker/workspace/main/install.sh | bash
```

Installs to `~/.workspace` and adds `~/.workspace/bin` to your `PATH`.

## Commands

| Command     | What it does                                                    |
| ----------- | --------------------------------------------------------------- |
| `init`      | Set up a project for workspace support (database.yml and lifecycle configs) |
| `bootstrap` | Set up a workspace — symlink shared files, run app setup, create isolated DBs |
| `run`       | Start the dev server for this workspace                         |
| `archive`   | Tear down a workspace — kill processes, drop DBs                |
| `prune`     | Clean resources for Git worktrees removed by an external tool    |
| `update`    | Pull the latest CLI from GitHub                                 |
| `version`   | Print the current version                                       |

## How it works

Run `workspace bootstrap` inside a sibling checkout (e.g. `myapp-feature-x` next to `myapp`) and it will:

1. Symlink shared files from the root checkout (`.env*`, `.bundle/`, `config/master.key`, `config/credentials/*.key`, `storage/`, `.tool-versions`, `ngrok.yml`).
2. Run the app's own setup script (`bin/setup`, `script/setup`, etc.).
3. Patch `config/database.yml` to suffix database names with the workspace name (idempotent).
4. Create the workspace-specific databases.
5. Write a `.workspace` file marking the workspace name.
6. Run `bin/workspace-bootstrap-hook` if present.

The root/default workspace is left alone — only siblings get isolated.

## Codex worktrees

When those files do not already exist, `workspace init` creates
`.codex/environments/environment.toml` with:

- A setup script that runs `workspace bootstrap` whenever Codex creates a worktree.
- A **Run** action that runs `workspace run`.
- An **Archive workspace** action for explicit manual teardown.

It also creates a project-local `SessionEnd` hook in `.codex/hooks.json`. Existing
Codex environment and hook files are left unchanged. Codex
does not distinguish an archived chat from an ordinary app close or idle
session in that hook, so the hook never archives the current workspace
directly. Instead, it schedules `workspace prune`, which waits for Git to
confirm that Codex removed the worktree before killing its ports and dropping
its databases.

After committing the generated `.codex` files, select the local environment in
Codex when starting a worktree chat. Review and trust the project hook when
Codex prompts; untrusted command hooks are skipped.

Codex-managed worktrees do not provide the Conductor-style root/name variables.
`workspace` recognizes linked worktrees under `$CODEX_HOME/worktrees` (default
`~/.codex/worktrees`) and reads their identity through Git's shared metadata,
including after a branch is attached. Worktrees created elsewhere retain their
existing behavior. Superconductor, Superset, and Conductor variables always
take precedence.

Cleanup registrations live under the repository's shared Git directory at
`.git/workspace/registry/`, so they survive deletion of the disposable
worktree. Cleanup is also reconciled on the next `workspace bootstrap` or
`workspace run` in case Codex was closed before its deferred hook completed.

## Hooks

Place any of these in your project's `bin/` directory to customize the workspace lifecycle. They must be executable (`chmod +x`).

| Hook | When it runs | How |
| ---- | ------------ | --- |
| `bin/workspace-seed` | After workspace DB schema load (during bootstrap) | Executed |
| `bin/workspace-bootstrap-hook` | After DB creation, seeding, and `.workspace` file written | Executed |
| `bin/workspace-run-hook` | Before foreman starts, after ports and `WORKSPACE_DB_SUFFIX` are exported | Sourced (can set env vars for the server) |
| `bin/workspace-archive-hook` | Before ports are swept and DBs dropped | Executed with `WORKSPACE_DB_SUFFIX` set |

`workspace init` generates a scaffold `bin/workspace-seed` with commented examples — uncomment the line that matches your project.

Examples:

```sh
# bin/workspace-seed — load fixtures into the workspace database
#!/bin/sh
RAILS_ENV=development bin/rails db:fixtures:load

# bin/workspace-run-hook — set an app-specific env var
#!/bin/sh
export DISABLE_SSL=true

# bin/workspace-archive-hook — clean up external resources
#!/bin/sh
bin/rails runner "Tenant.find_by(suffix: ENV['WORKSPACE_DB_SUFFIX'])&.destroy"
```

## Environment

- `WORKSPACE_HOME` — install location (default `~/.workspace`)
- `WORKSPACE_DB_SUFFIX` — exported during bootstrap/run as `_<workspace-name>`, used by the database.yml patch

## Tests

```sh
test/run_tests.sh
```
