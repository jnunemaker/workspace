---
name: workspace
description: Manage isolated app workspaces with the workspace CLI. Use when the user wants to set up, run, or tear down a sibling checkout of a project (different branch, isolated database, separate ports), customize the workspace lifecycle (seed, bootstrap, run, archive hooks), or onboard a project to workspace support. Triggers include "bootstrap", "archive workspace", "set up a new workspace", "workspace init", a `.workspace` file in the repo, or working in a Conductor / Superset / Superconductor environment.
---

# workspace

A CLI for running multiple isolated checkouts of the same app side-by-side — different branches, different databases, different ports — without them stepping on each other. Inspired by git worktrees: one *root* checkout holds the shared config (`.env`, `.bundle/`, `config/master.key`, `storage/`); *sibling* workspaces symlink to it and get suffixed databases.

Installed at `~/.workspace`. The CLI is `workspace`.

## When to use this skill

Invoke when the user wants to:

- **Onboard a project** to workspace support → `workspace init`
- **Spin up a sibling checkout** (feature branch, experiment) → `workspace bootstrap`
- **Start the dev server** inside a sibling → `workspace run`
- **Tear down a workspace** when done → `workspace archive`
- **Customize the lifecycle** (seeding, per-workspace env vars, external cleanup) → edit a hook in `bin/`
- **Debug workspace issues** (wrong DB name, missing symlink, hook not running)

Strong signals you're in workspace territory: a `.workspace` file in the repo, a `.conductor/settings.toml` / `.superconductor/config.json` / `.superset/config.json`, sibling directories like `myapp-feature-x` next to `myapp`, or the user mentioning Conductor / Superset / Superconductor.

## Commands

| Command | When to run | What it does |
| --- | --- | --- |
| `workspace init` | Once per project, in the root checkout | Patches `config/database.yml` for suffix-based isolation, creates `.conductor/settings.toml`, `.superconductor/config.json`, `.superset/config.json`, scaffolds `bin/workspace-seed`, adds `.workspace` to `.gitignore`. Idempotent. |
| `workspace bootstrap` | In each sibling checkout, after cloning or `git worktree add` | Symlinks shared files from root, runs the project's setup script (`bin/setup`, `script/setup`, etc.), patches `database.yml`, creates suffixed DBs, writes `.workspace`, runs `bin/workspace-seed` then `bin/workspace-bootstrap-hook`. In the root checkout, just runs setup with no isolation. |
| `workspace run` | To start the dev server in a sibling | Sources `bin/workspace-run-hook` (so it can `export` env vars), exports `WORKSPACE_DB_SUFFIX`, starts foreman. |
| `workspace archive` | When you're done with a sibling workspace | Runs `bin/workspace-archive-hook`, kills processes on the workspace's ports, drops the suffixed DBs. |
| `workspace update` | To pull the latest CLI | `git pull` in `~/.workspace` (or re-runs the installer). |
| `workspace version` | — | Prints the current version. |

## Lifecycle hooks

The project customizes the lifecycle by dropping executable scripts into its own `bin/` directory. **When debugging unexpected workspace behavior, check these first** — they hold the project-specific magic the CLI doesn't know about.

| Hook | When it runs | How |
| --- | --- | --- |
| `bin/workspace-seed` | After DB schema load during bootstrap | Executed |
| `bin/workspace-bootstrap-hook` | After DB creation, seeding, and `.workspace` file write | Executed |
| `bin/workspace-run-hook` | Before foreman starts (after ports + `WORKSPACE_DB_SUFFIX` are exported) | **Sourced** — can `export` env vars that affect the server |
| `bin/workspace-archive-hook` | Before ports are swept and DBs dropped | Executed with `WORKSPACE_DB_SUFFIX` set |

A hook that isn't executable (`chmod +x`) won't run.

## Key concepts

- **Root workspace**: the original checkout. It owns the shared config (`.env`, `.bundle/`, `config/master.key`, `config/credentials/*.key`, `storage/`, `.tool-versions`, `ngrok.yml`) and has no `.workspace` file. `workspace bootstrap` in the root just runs the project's setup script — no symlinking, no DB suffixing.
- **Sibling workspace**: any other checkout. Has a `.workspace` file containing its name. Gets `WORKSPACE_DB_SUFFIX=_<name>` exported during bootstrap and run, which the `database.yml` patch uses to suffix DB names (`myapp_development` → `myapp_development_<name>`).
- **Workspace name**: derived from the directory name (e.g. `myapp-feature-x` → `feature-x`). Superset names get sanitized — lowercased, special chars stripped. The actual name used is whatever's in `.workspace`.
- **Idempotency**: `init` and `bootstrap` are safe to re-run. The `database.yml` patch detects whether it's already applied.

## Common workflows

**Onboarding a project**

```sh
cd ~/projects/myapp        # the root checkout
workspace init             # patches files and scaffolds hooks
# Edit bin/workspace-seed — uncomment the line matching your seed strategy,
# or delete the file if the project doesn't need seeding.
git add . && git commit -m "Add workspace support"
```

**Spinning up a feature branch workspace**

```sh
cd ~/projects
git clone <repo> myapp-feature-x   # or: git worktree add ../myapp-feature-x feature-x
cd myapp-feature-x
workspace bootstrap                # symlinks, suffixed DBs, hooks all run
workspace run                      # start the dev server
```

**Tearing down**

```sh
cd ~/projects/myapp-feature-x
workspace archive                  # drops the suffixed DBs, kills ports
cd .. && rm -rf myapp-feature-x
```

## Gotchas

- `workspace bootstrap` in the root checkout intentionally skips isolation. If you expected suffixed DBs there, you're in the wrong directory.
- Symlinks are created with `ln -sfn`; if a real directory exists where a symlink should be (e.g. a real `.bundle/`), bootstrap deletes it first. Don't keep workspace-specific data in those paths.
- `.env` is *symlinked*, not copied. Edits in any sibling affect the shared file.
- The `database.yml` patch matches a specific shape. Hand-edited unusual `database.yml` files may not patch cleanly — check the diff after `init`.
- `workspace-run-hook` is **sourced**, the others are **executed**. Use `export` in run-hook; use plain commands elsewhere.

## Reference

- Source: <https://github.com/jnunemaker/workspace>
- Local install: `~/.workspace` (CLI in `~/.workspace/bin/workspace`, lib scripts in `~/.workspace/lib/`)
- Environment: `WORKSPACE_HOME` (install location), `WORKSPACE_DB_SUFFIX` (exported during bootstrap/run)
