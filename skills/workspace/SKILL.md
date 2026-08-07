---
name: workspace
description: Manage isolated app workspaces with the workspace CLI. Use when the user wants to set up, run, or tear down a sibling checkout of a project (different branch, isolated database, separate ports), customize the workspace lifecycle (database, seed, bootstrap, run, archive hooks), or onboard a project to workspace support. Triggers include "bootstrap", "archive workspace", "set up a new workspace", "workspace init", a `.workspace` file in the repo, or working in a Conductor / Superset / Superconductor environment.
---

# workspace

A CLI for running multiple isolated checkouts of the same app side-by-side — different branches, different databases, different ports — without them stepping on each other. Inspired by git worktrees: one *root* checkout holds the shared config (`.env`, `.bundle/`, `config/master.key`, `storage/`); *sibling* workspaces symlink to it and get suffixed databases.

Installed at `~/.workspace`. The CLI is `workspace`.

## When to use this skill

Invoke when the user wants to:

- **Onboard a project** to workspace support → `workspace init`
- **Spin up a sibling checkout** (feature branch, experiment) → `bin/workspace bootstrap`
- **Start the dev server** inside a sibling → `bin/workspace run`
- **Tear down a workspace** when done → `bin/workspace archive`
- **Customize the lifecycle** (seeding, per-workspace env vars, external cleanup) → edit a hook in `bin/`
- **Debug workspace issues** (wrong DB name, missing symlink, hook not running)

Strong signals you're in workspace territory: a `.workspace` file in the repo, a `.conductor/settings.toml` / `.superconductor/config.json` / `.superset/config.json`, sibling directories like `myapp-feature-x` next to `myapp`, or the user mentioning Conductor / Superset / Superconductor.

## Commands

| Command | When to run | What it does |
| --- | --- | --- |
| `workspace init` | Once per project, in the root checkout | Patches `config/database.yml`, creates `bin/workspace` plus `.workspace-version`, and creates/updates provider configs to use the shim. Does not scaffold optional hooks. Idempotent. |
| `bin/workspace bootstrap` | In each sibling checkout, after cloning or `git worktree add` | Links untracked shared files, exports the suffix, runs the dedicated setup hook (or legacy setup fallback), prepares databases, writes `.workspace`, and runs optional post-setup hooks. In root, only runs ordinary setup. Never runs `bin/update`. |
| `bin/workspace run` | To start the dev server in a sibling | Loads linked `.env` defaults, exports ports and `WORKSPACE_DB_SUFFIX`, sources `bin/workspace-run-hook`, displays its optional `WORKSPACE_APP_URL`, then starts foreman. |
| `bin/workspace archive` | When you're done with a sibling workspace | Runs `bin/workspace-archive-hook`, kills processes on the workspace's ports, drops the suffixed DBs. |
| `bin/workspace info` | To inspect any initialized checkout | Prints provider, name, root, suffix, URL, and the allocated 10-port block. |
| `bin/workspace update` | To pull the latest CLI after initialization | Bypasses the repository minimum-version check so an outdated install can update. |
| `bin/workspace version` | — | Prints the current version. |

## Lifecycle hooks

The project customizes the lifecycle by dropping executable scripts into its own `bin/` directory. **When debugging unexpected workspace behavior, check these first** — they hold the project-specific magic the CLI doesn't know about.

| Hook | When it runs | How |
| --- | --- | --- |
| `bin/workspace-identity-hook` | Before lifecycle work when neither `.conductor-workspace` nor `.workspace` exists; print the established name without `_` | Executed with `WORKSPACE_PROVIDER`, `WORKSPACE_ROOT_PATH`, and derived `WORKSPACE_NAME` exported; empty output defers to provider/Git defaults |
| `bin/workspace-database-hook` | Before project setup, with `WORKSPACE_DB_SUFFIX` exported; materialize local `database.yml` here when needed | Executed |
| `bin/workspace-setup-hook` | After shared files and `WORKSPACE_DB_SUFFIX`, before Workspace prepares dev/test databases; prevents the legacy setup fallback in managed siblings | Executed |
| `bin/workspace-seed` | After `db:prepare` during bootstrap | Executed |
| `bin/workspace-bootstrap-hook` | After DB preparation, seeding, and `.workspace` file write | Executed |
| `bin/workspace-run-hook` | Before foreman starts (after dotenv, ports, and `WORKSPACE_DB_SUFFIX`) | **Sourced** — can export server variables and set `WORKSPACE_APP_URL` for display |
| `bin/workspace-archive-hook` | Before ports are swept and DBs dropped | Executed with `WORKSPACE_DB_SUFFIX` set |

A hook that isn't executable (`chmod +x`) won't run. Every hook is optional;
`workspace init` does not create empty hook files.

## Key concepts

- **Root workspace**: the original checkout. It owns shared untracked config and has no `.workspace` file. Normal development remains `bin/setup` once, `bin/update` after pulls, and `bin/dev` to run. `workspace bootstrap` there only uses ordinary setup detection — no managed hooks, linking, suffixing, database preparation, or `bin/update`.
- **Sibling workspace**: any other checkout. Has a `.workspace` file containing its name. Gets `WORKSPACE_DB_SUFFIX=_<name>` exported during bootstrap and run, which the `database.yml` patch uses to suffix DB names (`myapp_development` → `myapp_development_<name>`).
- **Workspace name**: resolved consistently by every command. A non-empty `.conductor-workspace` wins for an existing integration, followed by `.workspace`, `bin/workspace-identity-hook`, provider variables, then the stable ID of any linked Git worktree. Markerless Superset identities retain the provider's historical 45-character limit; Superconductor and generic Git identities use 40 characters. The main checkout remains unsuffixed.
- **Idempotency**: `init` and `bootstrap` are safe to re-run. The `database.yml` patch detects whether it's already applied.

## Common workflows

**Onboarding a project**

```sh
cd ~/projects/myapp        # the root checkout
workspace init             # patches files and creates provider-neutral configs
# Add only the optional bin/workspace-*-hook scripts the project actually needs.
git add . && git commit -m "Add workspace support"
```

**Spinning up a feature branch workspace**

```sh
cd ~/projects
git clone <repo> myapp-feature-x   # or: git worktree add ../myapp-feature-x feature-x
cd myapp-feature-x
bin/workspace bootstrap            # symlinks, suffixed DBs, hooks all run
bin/workspace run                  # start the dev server
```

**Tearing down**

```sh
cd ~/projects/myapp-feature-x
bin/workspace archive              # drops the suffixed DBs, kills ports
cd .. && rm -rf myapp-feature-x
```

## Gotchas

- `workspace bootstrap` in the root checkout intentionally skips isolation. If you expected suffixed DBs there, you're in the wrong directory.
- Tracked files such as `.tool-versions` are never replaced with root symlinks. Shared directories such as `.bundle/` and `storage/` are also preserved when they contain tracked descendants; untracked-only directories retain the historical root-linking behavior.
- `.env` is *symlinked*, not copied. Edits in any sibling affect the shared file.
- The `database.yml` patch matches a specific shape. Hand-edited unusual `database.yml` files may not patch cleanly — check the diff after `init`.
- `workspace-run-hook` is **sourced**, the others are **executed**. Use `export` in run-hook; use plain commands elsewhere. Set `WORKSPACE_APP_URL` there when the generic localhost URL is inaccurate.
- Generated provider configs call `bin/workspace`, which tries PATH and then `${WORKSPACE_HOME:-$HOME/.workspace}`. It reports an install command when missing and an exact update command when older than `.workspace-version`; it never downloads code automatically.
- Empty or malformed `.workspace` identities fail closed instead of silently selecting another database. Existing non-empty `.conductor-workspace` files remain authoritative and are mirrored to `.workspace` after successful bootstrap.

## Reference

- Source: <https://github.com/jnunemaker/workspace>
- Local install: `~/.workspace` (CLI in `~/.workspace/bin/workspace`, lib scripts in `~/.workspace/lib/`)
- Environment: `WORKSPACE_HOME` (install location), `WORKSPACE_PORT` (optional base-port override), `WORKSPACE_DB_SUFFIX` (exported during bootstrap/run), `WORKSPACE_APP_URL` (optional displayed URL from the run hook)
