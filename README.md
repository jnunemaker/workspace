# workspace

A small CLI for running multiple isolated checkouts of the same app side-by-side — different branches, different databases, different ports — without them stepping on each other.

Inspired by git worktrees: one "root" checkout holds the shared config (`.env`, `.bundle`, `config/master.key`, `storage/`, etc.), and additional workspaces symlink to it and get their own suffixed databases.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jnunemaker/workspace/main/install.sh | bash
```

Installs to `~/.workspace` and adds `~/.workspace/bin` to your `PATH`.

## Quick start

Initialize each application from its root checkout:

```sh
cd ~/projects/myapp
workspace init
git status --short
git diff
# Repeat for every generated path marked ?? above, for example:
git diff --no-index /dev/null bin/workspace
```

Review the generated shim, minimum-version contract, provider configuration,
and `config/database.yml` changes. `git diff` omits untracked files, so inspect
every `??` path separately with `git diff --no-index /dev/null path/from/status`
(the command exits nonzero when it displays a difference). Add any
project-specific lifecycle hooks the application needs, then stage and commit
only the files you reviewed.

From a sibling checkout created by a supported manager or `git worktree add`,
use the committed project entrypoint for the normal lifecycle:

```sh
bin/workspace bootstrap
bin/workspace info
bin/workspace run

# When the sibling is no longer needed:
bin/workspace archive
```

Codex, Conductor, Superset, and Superconductor use the same `bin/workspace`
entrypoint from their generated project configuration. The root checkout keeps
using the application's ordinary `bin/setup`, `bin/update`, and `bin/dev`
commands.

A separate plain `git clone` is another root/default checkout. Sibling
isolation requires an identity supplied by a supported manager or a linked Git
worktree created with `git worktree add`.

## Commands

| Command     | What it does                                                    |
| ----------- | --------------------------------------------------------------- |
| `init`      | Set up a project for workspace support (database.yml and lifecycle configs) |
| `bootstrap` | Set up a workspace — symlink shared files, run app setup, create isolated DBs |
| `run`       | Start the dev server for this workspace                         |
| `archive`   | Tear down a workspace — kill processes, drop DBs                |
| `info`      | Show provider, identity, URL, suffix, and allocated ports       |
| `prune`     | Clean resources for Git worktrees removed by an external tool    |
| `update`    | Pull the latest shared CLI and refresh the installed agent skill |
| `version`   | Print the current version                                       |

## How it works

Run `bin/workspace bootstrap` inside a sibling checkout (e.g. `myapp-feature-x` next to `myapp`) and it will:

1. Resolve one stable database identity from existing markers, a project hook, provider variables, or Git worktree metadata.
2. Link untracked shared files and directories from the root checkout. Tracked files such as `.tool-versions`, and shared directories containing tracked descendants, remain owned by the sibling branch and are never replaced with root symlinks.
3. Load the shared environment and export `WORKSPACE_DB_SUFFIX`.
4. Source `bin/workspace-environment-hook` when present so project-selected PATH and toolchain state apply to every later project command.
5. Run `bin/workspace-database-hook` when present, then patch an existing `config/database.yml` for isolation.
6. Run `bin/workspace-setup-hook` when present. If it is absent, fall back to `bin/setup`, `script/setup`, or `script/bootstrap` for compatibility, then patch again in case that fallback generated `database.yml`.
7. Prepare the workspace-specific databases with Rails `db:prepare`. On older Rails applications that do not define that task, safely fall back to `db:create` followed by `db:migrate`.
8. Run the optional seed hook, atomically write `.workspace`, then run the optional bootstrap hook.

The root/default checkout keeps the normal application-development contract:
`bin/setup` for first setup, `bin/update` after pulls, and `bin/dev` to run.
`workspace bootstrap` there sources the environment hook before ordinary setup;
it does not run managed-only hooks, link files, suffix databases, or call
`bin/update`.
Workspace lifecycle commands never invoke `bin/update`.

`workspace init` creates a committed project entrypoint at `bin/workspace` and a
minimum revision contract at `.workspace-version`. Generated Codex, Conductor,
Superset, and Superconductor commands use this entrypoint. It first tries
`workspace` on `PATH`, then `${WORKSPACE_HOME:-$HOME/.workspace}/bin/workspace`,
so provider shells do not need to load user dotfiles. A missing install prints
the one-time install command; an older install prints the exact update command.
It never installs or updates Workspace automatically.

Use `bin/workspace info` to see the provider, workspace name, root path,
database suffix, application URL, and reserved 10-port block.

## Updating Workspace

From any initialized application, update the shared Workspace installation
with:

```sh
bin/workspace update
```

This pulls the latest CLI and refreshes the installed Claude Code/Codex skill.
It does not rewrite files in the application repository.

When the application should adopt newer generated integration files, return to
its root checkout and run:

```sh
workspace init
git status --short
git diff
# Repeat for every generated path marked ?? above, for example:
git diff --no-index /dev/null bin/workspace
```

`workspace init` refreshes Workspace-owned project files such as
`bin/workspace`, `.workspace-version`, and recognized provider configuration;
it may also update the database isolation patch. Review the complete diff and
every untracked generated file, then commit only the intended changes. This
refresh is explicit: updating your personal CLI does not require every
application repository to change.

## Stable database identity

Every lifecycle command resolves the workspace name in the same order:

1. A non-empty `.conductor-workspace`, for existing Conductor-family projects.
2. `.workspace`, written by a successful Workspace bootstrap.
3. Executable `bin/workspace-identity-hook`, for a project with another established identity scheme.
4. The name supplied by Superconductor, Superset, or Conductor.
5. The stable Git worktree ID for any linked Git worktree.

The main Git checkout has no worktree ID and remains unsuffixed. Provider names
are sanitized when needed before they become defaults. Superset retains its
historical 45-character identity limit; Superconductor and generic Git
worktrees use 40 characters. Existing identity files and hook output are
validated but never silently rewritten or truncated. This keeps `bootstrap`,
`run`, `info`, `archive`, and ad-hoc Rails commands on the same database after
a provider display-name, directory, or branch rename.

An identity hook prints the established workspace name without the leading
underscore. It may print nothing to defer to provider/Git detection. Workspace
exports `WORKSPACE_PROVIDER`, `WORKSPACE_ROOT_PATH`, and the detected
`WORKSPACE_NAME` while invoking it. Once either marker exists, the hook is not
called. A non-empty `.conductor-workspace` remains authoritative for the
worktree until the project removes it.

## Codex worktrees

When those files do not already exist, `workspace init` creates
`.codex/environments/environment.toml` with:

- A setup script that runs `bin/workspace bootstrap` whenever Codex creates a worktree.
- A native cleanup script that runs the disposable worktree's `bin/workspace archive` before Codex removes it. It prefers `CODEX_WORKTREE_PATH` when available; current Codex cleanup runs inside the worktree without exporting that setup-only variable, so Workspace verifies the current checkout is a linked Git worktree before using it.
- **Run** and **Workspace info** actions that use `bin/workspace`.
- An **Archive workspace** action for explicit manual teardown.

Native cleanup is the normal Codex teardown path, so archive failures remain
visible instead of being reported as successful cleanup. In existing Codex
files, recognized Workspace commands are upgraded to use the shim, a missing
native cleanup is added, and a missing **Workspace info** action is added.
Exact older Workspace cleanup defaults are upgraded; custom cleanup commands
and linked configuration files are left unchanged.

`workspace init` also keeps a project-local `SessionEnd` hook in
`.codex/hooks.json` as recovery for older Codex versions, interrupted cleanup,
forced worktree deletion, and app shutdown. SessionEnd does not distinguish an
archived chat from an ordinary app close or idle session, so it never archives
the current checkout directly. It schedules `workspace prune --deferred`,
which waits for Git to confirm that Codex removed the worktree before killing
its ports and dropping its databases.

After committing the generated `.codex` files, select the local environment in
Codex when starting a worktree chat. Review and trust the project hook when
Codex prompts; untrusted command hooks are skipped.

`CODEX_SOURCE_TREE_PATH` and `CODEX_WORKTREE_PATH` locate Codex checkouts when
Codex provides them; they never construct `WORKSPACE_NAME` or
`WORKSPACE_DB_SUFFIX`. Cleanup may instead use its verified linked-worktree
working directory. In either case, the same provider-neutral identity resolver used by every other
lifecycle command reads stable markers, hooks, provider variables, and Git
metadata. Superconductor, Superset, and Conductor variables always take
precedence over Git detection.

Cleanup registrations live under the repository's shared Git directory at
`.git/workspace/registry/`, so they survive deletion of the disposable
worktree. The registry, deferred SessionEnd prune, and reconciliation on the
next `workspace bootstrap` or `workspace run` are recovery mechanisms when
native cleanup could not complete.

## Hooks

Place any of these in your project's `bin/` directory to customize the workspace lifecycle. Executed hooks must be executable (`chmod +x`); sourced hooks only need to be readable.

| Hook | When it runs | How |
| ---- | ------------ | --- |
| `bin/workspace-identity-hook` | Before lifecycle work when neither identity marker exists; print an established workspace name without the `_` prefix | Executed; empty output defers to provider/Git defaults |
| `bin/workspace-environment-hook` | After identity, dotenv, and suffix resolution but before project-owned or runtime-dependent bootstrap, run, and archive work; also before ordinary setup in the root checkout | Sourced into the lifecycle shell; exported PATH and variables persist |
| `bin/workspace-database-hook` | Before project setup, with `WORKSPACE_DB_SUFFIX` exported; use it to materialize `config/database.yml` locally | Executed |
| `bin/workspace-setup-hook` | After shared files and `WORKSPACE_DB_SUFFIX` are available, before Workspace prepares development/test databases; replaces ordinary setup fallback for managed siblings | Executed |
| `bin/workspace-seed` | After workspace databases are prepared (during bootstrap) | Executed |
| `bin/workspace-bootstrap-hook` | After DB preparation, seeding, and `.workspace` file written | Executed |
| `bin/workspace-run-hook` | Before foreman starts, after dotenv, ports, and `WORKSPACE_DB_SUFFIX` are exported | Sourced (can set env vars and `WORKSPACE_APP_URL` for the server) |
| `bin/workspace-archive-hook` | Before ports are swept and DBs dropped | Executed with `WORKSPACE_DB_SUFFIX` set |

Use `bin/workspace-setup-hook` for dependency installation or other setup that
belongs only to managed sibling workspaces. Keep `bin/setup`, `bin/update`, and
`bin/dev` focused on ordinary root-checkout development. If database
configuration must exist before the setup hook itself runs, materialize it in
`bin/workspace-database-hook`. Existing projects without the dedicated setup
hook retain the legacy setup fallback.

All hooks are optional. `workspace init` deliberately does not scaffold empty
hooks; add and commit only the hooks the project actually needs.

Use `bin/workspace-environment-hook` when the project runtime is not already on
the non-interactive shell's PATH. It is the project-owned integration point for
mise, asdf, rbenv, Nix, direnv, or another toolchain manager; Workspace does not
install, detect, or require any of them. Because the file is sourced by
`/bin/sh`, keep it POSIX-shell compatible and use `export` for values that must
reach setup scripts, Rails, Foreman, or cleanup hooks. A nonzero result stops
the lifecycle before those commands run.

Examples:

```sh
# bin/workspace-environment-hook — activate the project's chosen toolchain
# Use the manager's normal POSIX-shell activation here. For example:
export PATH="$HOME/.local/share/mise/shims:$HOME/.rbenv/shims:$PATH"

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
- `WORKSPACE_PORT` — optional provider-neutral base-port override
- `WORKSPACE_DB_SUFFIX` — exported during bootstrap/run as `_<workspace-name>`, used by the database.yml patch
- `WORKSPACE_SKIP_CLAUDE_SKILL` — set to `1` to skip the Claude Code skill install
- `WORKSPACE_SKIP_CODEX_SKILL` — set to `1` to skip the Codex skill install
- `WORKSPACE_APP_URL` — set by `bin/workspace-run-hook` to override the URL displayed before Foreman starts

`workspace run` loads the linked `.env` as defaults before sourcing the run hook. Values already exported by the workspace manager, and values exported by the hook, take precedence. Keep `.env` shell-compatible because the CLI sources it with `/bin/sh`.
Workspace honors `SUPERCONDUCTOR_PORT`, `SUPERSET_PORT`, and `CONDUCTOR_PORT`
when supplied; otherwise named worktrees receive a deterministic 10-port block.

## Tests

```sh
test/run_tests.sh
```
