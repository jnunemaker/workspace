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
2. Run `bin/workspace-database-hook` when present, then patch an existing `config/database.yml` for isolation.
3. Run the app's own setup script (`bin/setup`, `script/setup`, etc.), then patch again in case setup generated `database.yml`.
4. Prepare the workspace-specific databases with Rails `db:prepare`. On older Rails applications that do not define that task, safely fall back to `db:create` followed by `db:migrate`.
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
| `bin/workspace-database-hook` | Before project setup, with `WORKSPACE_DB_SUFFIX` exported; use it to materialize `config/database.yml` locally | Executed |
| `bin/workspace-seed` | After workspace databases are prepared (during bootstrap) | Executed |
| `bin/workspace-bootstrap-hook` | After DB preparation, seeding, and `.workspace` file written | Executed |
| `bin/workspace-run-hook` | Before foreman starts, after dotenv, ports, and `WORKSPACE_DB_SUFFIX` are exported | Sourced (can set env vars and `WORKSPACE_APP_URL` for the server) |
| `bin/workspace-archive-hook` | Before ports are swept and DBs dropped | Executed with `WORKSPACE_DB_SUFFIX` set |

If a project's setup script both creates `config/database.yml` and immediately
uses the database, move only the configuration-materialization step into
`bin/workspace-database-hook`. That project-specific split cannot be inferred
safely by the generic workspace lifecycle. Setup scripts that only create the
file remain supported without a hook.

`workspace init` generates a scaffold `bin/workspace-seed` with commented examples — uncomment the line that matches your project.

Examples:

```sh
# bin/workspace-seed — load fixtures into the workspace database
#!/bin/sh
RAILS_ENV=development bin/rails db:fixtures:load

# bin/workspace-run-hook — set an app-specific env var
#!/bin/sh
export DISABLE_SSL=true
WORKSPACE_APP_URL="https://my-feature.example.test"

# bin/workspace-archive-hook — clean up external resources
#!/bin/sh
bin/rails runner "Tenant.find_by(suffix: ENV['WORKSPACE_DB_SUFFIX'])&.destroy"
```

## Claude Code and Codex skill

If you have [Claude Code](https://claude.com/claude-code) or Codex installed, the installer also symlinks the workspace skill into the existing `~/.claude/skills/workspace/` and `${CODEX_HOME:-~/.codex}/skills/workspace/` directories. The skill teaches both agents when to run `init` vs `bootstrap`, what the lifecycle hooks do, and the common workflows. It updates automatically whenever you run `workspace update`.

To skip either install, set `WORKSPACE_SKIP_CLAUDE_SKILL=1` or `WORKSPACE_SKIP_CODEX_SKILL=1` before running the installer.

## Environment

- `WORKSPACE_HOME` — install location (default `~/.workspace`)
- `WORKSPACE_DB_SUFFIX` — exported during bootstrap/run as `_<workspace-name>`, used by the database.yml patch
- `WORKSPACE_SKIP_CLAUDE_SKILL` — set to `1` to skip the Claude Code skill install
- `WORKSPACE_SKIP_CODEX_SKILL` — set to `1` to skip the Codex skill install
- `WORKSPACE_APP_URL` — set by `bin/workspace-run-hook` to override the URL displayed before Foreman starts

`workspace run` loads the linked `.env` as defaults before sourcing the run hook. Values already exported by the workspace manager, and values exported by the hook, take precedence. Keep `.env` shell-compatible because the CLI sources it with `/bin/sh`.

## Tests

```sh
test/run_tests.sh
```
