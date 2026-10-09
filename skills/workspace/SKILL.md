---
name: workspace
description: Manage isolated app workspaces with the workspace CLI. Use when the user wants to set up, run, or tear down a sibling checkout of a project (different branch, isolated database, separate ports), customize the workspace lifecycle (database, seed, bootstrap, run, archive hooks), or onboard a project to workspace support. Triggers include "bootstrap", "archive workspace", "set up a new workspace", "workspace init", a `.workspace` file in the repo, or working in a Conductor / Superset / Superconductor environment.
---

# workspace

A CLI for running multiple isolated checkouts of the same app side-by-side — different branches, different databases, different ports — without them stepping on each other. Inspired by git worktrees: one *root* checkout holds the shared config (`.env`, `.bundle/`, `config/master.key`, `storage/`); *sibling* workspaces symlink to it and get suffixed databases.

Installed at `~/.workspace`. The CLI is `workspace`.

## When to use this skill

Invoke when the user wants to:

- **Onboard a project or refresh its generated integration files** → `workspace init` from the root checkout
- **Spin up a sibling checkout** (feature branch, experiment) → `bin/workspace bootstrap`
- **Start the dev server** inside a sibling → `bin/workspace run`
- **Tear down a workspace** when done → `bin/workspace archive`
- **Customize the lifecycle** (seeding, per-workspace env vars, external cleanup) → edit a hook in `bin/`
- **Debug workspace issues** (wrong DB name, missing symlink, hook not running)

Strong signals you're in workspace territory: a `.workspace` file in the repo, a `.conductor/settings.toml` / `.superconductor/config.json` / `.superset/config.json` / `.codex/environments/environment.toml`, Workspace hooks in `.claude/settings.json`, sibling directories like `myapp-feature-x` next to `myapp`, or the user mentioning Conductor / Superset / Superconductor.

## Commands

| Command | When to run | What it does |
| --- | --- | --- |
| `workspace init` | During onboarding, or later when intentionally refreshing generated files; run from the root checkout | Patches `config/database.yml`, creates/updates `bin/workspace` plus `.workspace-version`, and creates/updates recognized provider configs to use the shim. Does not scaffold optional hooks. Idempotent. |
| `bin/workspace bootstrap` | In each manager-created sibling or linked checkout created with `git worktree add` | Links untracked shared files, exports the suffix, publishes Git cleanup registration, sources the environment hook, runs the dedicated setup hook (or legacy setup fallback), prepares databases, writes `.workspace`, and runs optional post-setup hooks. In root, sources the environment hook before ordinary setup. Never runs `bin/update`. |
| `bin/workspace run` | To start the dev server in a sibling | Loads linked `.env` defaults, reserves a Git port and exports `WORKSPACE_DB_SUFFIX`, sources the environment hook, computes authoritative service ports, sources `bin/workspace-run-hook`, displays the configured application URL, then starts foreman. |
| `bin/workspace archive` | When you're done with a sibling workspace | Sources the environment hook, runs `bin/workspace-archive-hook`, kills processes on the workspace's ports, and drops the suffixed DBs. |
| `bin/workspace prune` | From the root or any remaining checkout after an external tool removes Git worktrees | Reconciles the shared Git registry and archives resources for worktrees that no longer exist. Safe to re-run. |
| `bin/workspace info` | To inspect any initialized checkout | Prints provider, name, root, suffix, URL, and the allocated 10-port block. |
| `bin/workspace update` | To update the shared CLI after initialization | Pulls the latest installed CLI and refreshes the linked agent skill. It bypasses the repository minimum-version check so an outdated install can update, but does not rewrite application files. |
| `bin/workspace version` | — | Prints the current version. |

## Lifecycle hooks

The project customizes the lifecycle with scripts in its own `bin/` directory. Every hook except `bin/workspace-environment-hook` requires executable mode; the environment hook is sourced as a regular readable file. **When debugging unexpected workspace behavior, check these first** — they hold the project-specific magic the CLI doesn't know about.

| Hook | When it runs | How |
| --- | --- | --- |
| `bin/workspace-identity-hook` | Before isolated sibling lifecycle work when neither `.conductor-workspace` nor `.workspace` exists; print the established name without `_` | Executed with `WORKSPACE_PROVIDER`, `WORKSPACE_ROOT_PATH`, and derived `WORKSPACE_NAME` exported; empty output defers to provider/Git defaults; never called for the root/default checkout |
| `bin/workspace-environment-hook` | Before project-owned or runtime-dependent bootstrap, run, and archive work; also before ordinary root setup | **Sourced** after resolved provider state is exported; PATH and other exports persist into setup, Rails, Foreman, and cleanup |
| `bin/workspace-database-hook` | When present, before project setup, with `WORKSPACE_DB_SUFFIX` and a resolved `WORKSPACE_ROOT_PATH` when available; use the root path to copy database configuration when needed | Executed from the workspace checkout, not the original checkout |
| `bin/workspace-setup-hook` | After shared files and `WORKSPACE_DB_SUFFIX`, before Workspace prepares dev/test databases; prevents the legacy setup fallback in managed siblings | Executed |
| `bin/workspace-seed` | After `db:prepare` during bootstrap | Executed |
| `bin/workspace-bootstrap-hook` | After DB preparation, seeding, and `.workspace` file write | Executed |
| `bin/workspace-run-hook` | Before foreman starts (after dotenv, ports, and `WORKSPACE_DB_SUFFIX`) | **Sourced when executable** — can export server variables; legacy `WORKSPACE_APP_URL` overrides affect only `run` |
| `bin/workspace-archive-hook` | Before ports are swept and DBs dropped | Executed with `WORKSPACE_DB_SUFFIX` set |

Every hook is optional, and `workspace init` does not create empty hook files.
The environment hook is sourced without requiring executable mode. The run hook
is also sourced, but executable mode remains its opt-in; all other hooks are
executed and require `chmod +x`. Keep sourced hooks POSIX `/bin/sh` compatible
and export changes that subprocesses need. Use the environment hook for
project-owned activation of mise, asdf, rbenv, Nix, direnv, or another manager;
Workspace does not assume or require a specific runtime manager. A nonzero hook
result stops the current lifecycle.

`WORKSPACE_ROOT_PATH` is the path to the original checkout. A database hook can
use it to copy a file such as `config/database.yml`, even though the hook runs
from the workspace checkout. When the resolved path names an existing
directory, Workspace guarantees that the database hook receives it unchanged.

## Key concepts

- **Root workspace**: the original checkout. It owns shared untracked config and has no `.workspace` file. Normal development remains `bin/setup` once, `bin/update` after pulls, and `bin/dev` to run. `workspace bootstrap` there sources the environment hook before ordinary setup — no managed-only hooks, linking, suffixing, database preparation, or `bin/update`.
- **Sibling workspace**: any other checkout. Has a `.workspace` file containing its name. Gets `WORKSPACE_DB_SUFFIX=_<name>` exported during bootstrap and run, which the `database.yml` patch uses to suffix DB names (`myapp_development` → `myapp_development_<name>`).
- **Ad-hoc Rails commands**: bootstrap resolves the full identity precedence and persists the chosen name to `.workspace`. The generated `database.yml` helper uses `WORKSPACE_DB_SUFFIX` when exported and otherwise reads only that persisted `.workspace` marker. It does not directly inspect `.conductor-workspace`, provider variables, Git metadata, or the identity hook. Run bootstrap first so a sibling has a stable marker before using `bin/rails console`, migrations, or runners directly.
- **Workspace name**: resolved consistently by every lifecycle command. A non-empty `.conductor-workspace` wins for an existing integration, followed by `.workspace`, `bin/workspace-identity-hook`, provider variables, then the stable ID of any linked Git worktree. Markerless Superset identities retain the provider's historical 45-character limit; Superconductor and generic Git identities use 40 characters. The main checkout remains unsuffixed.
- **Codex cleanup**: the generated native cleanup script is the happy path. It prefers the quoted `CODEX_WORKTREE_PATH` when available. Current Codex instead starts cleanup inside the disposable worktree without exporting that setup-only variable, so Workspace verifies that the current checkout is a linked Git worktree before invoking its `bin/workspace archive`. Paths locate checkouts only; they never define the workspace name or database suffix.
- **Claude Code worktrees**: Claude Code (including Claude desktop worktree sessions) has no native setup/cleanup scripts. `init` merges `SessionStart` and `SessionEnd` hooks into `.claude/settings.json` that run `"$CLAUDE_PROJECT_DIR"/bin/workspace claude-hook session-start|session-end`. Hooks run from the original checkout; `claude-hook` reads the worktree from the hook JSON `cwd`. Start bootstraps once (`bootstrap --once`) and records the branch if the session started on one; end archives in the background only when a session that started on its branch ends detached (desktop archive detaches HEAD and never deletes the worktree), waiting for any setup still running. Sessions that start or resume detached are never archived automatically — run `bin/workspace archive` by hand. Unarchive re-bootstraps. Archive logs go to `workspace-claude.log` in the worktree's Git dir.
- **Cleanup recovery**: the shared Git registry survives worktree deletion. The SessionEnd `bin/workspace prune --deferred` hook and bootstrap/run reconciliation remain fallbacks for older Codex versions, interrupted cleanup, forced deletion, and app shutdown.
- **Idempotency**: `init` and `bootstrap` are safe to re-run. The `database.yml` patch detects whether it's already applied.

## Common workflows

**Onboarding a project**

For custom hostnames, follow [Project application URL](#project-application-url)
so `info` and `run` can display the same address.

```sh
cd ~/projects/myapp        # the root checkout
workspace init             # patches files and creates provider-neutral configs
# Add only the optional bin/workspace-*-hook scripts the project actually needs.
git status --short
git diff
# Repeat for every generated path marked ?? above, for example:
git diff --no-index /dev/null bin/workspace
```

Review `config/database.yml`, the generated shim/version contract, provider
configuration, and any hooks. `git diff` omits untracked files, so inspect every
`??` path separately with `git diff --no-index /dev/null path/from/status`; its
nonzero status is expected when it displays a difference. Stage and commit only
the files you reviewed; do not use a blanket `git add .` in a repository with
unrelated changes.

**Updating Workspace and generated project files**

```sh
bin/workspace update       # updates the shared CLI and installed agent skill

cd ~/projects/myapp        # return to the root checkout
workspace init             # explicitly refresh project-owned generated files
git status --short
git diff
# Repeat for every generated path marked ?? above, for example:
git diff --no-index /dev/null bin/workspace
```

`bin/workspace update` does not alter the application repository. Run
`workspace init` afterward only when the application should adopt the latest
shim, minimum revision, database patch, or recognized provider configuration;
review tracked changes and every `??` generated file before committing.

**Spinning up a feature branch workspace**

```sh
cd ~/projects
cd myapp
git worktree add -b feature-x ../myapp-feature-x
cd ..
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
- A separate plain `git clone` is another root/default checkout. Sibling isolation requires an identity supplied by a supported manager or a linked Git worktree created with `git worktree add`.
- Tracked files such as `.tool-versions` are never replaced with root symlinks. Shared directories such as `.bundle/` and `storage/` are also preserved when they contain tracked descendants; untracked-only directories retain the historical root-linking behavior.
- `.env` is *symlinked*, not copied. Edits in any sibling affect the shared file.
- The `database.yml` patch matches a specific shape. Hand-edited unusual `database.yml` files may not patch cleanly — check the diff after `init`.
- `workspace-environment-hook` and `workspace-run-hook` are **sourced**; the others are **executed**. Use `export` in sourced hooks; use plain commands elsewhere. Keep toolchain activation in the environment hook. Configure shared display URLs as described below; `info` does not source either hook.
- Generated provider configs call `bin/workspace`, which tries PATH and then `${WORKSPACE_HOME:-$HOME/.workspace}`. It reports an install command when missing and an exact update command when older than `.workspace-version`; it never downloads code automatically.
- `.workspace` must be non-empty; an empty `.conductor-workspace` retains its legacy unpinned behavior. Both marker paths must be regular, non-symlink files. Reserved, multiline, and control-character identities fail closed instead of silently selecting another database. Existing non-empty `.conductor-workspace` files remain authoritative and are mirrored to `.workspace` after successful bootstrap.
- Generic Git worktrees are registered so cleanup can recover after an external tool deletes their directories or native Codex cleanup is interrupted. Run `bin/workspace prune` from a surviving checkout to reconcile immediately; the SessionEnd deferred prune and normal bootstrap/run reconciliation are fallback paths. Archive cleans only its current workspace.
- Port precedence is `WORKSPACE_PORT`, an existing Git registry reservation, `SUPERCONDUCTOR_PORT`, `SUPERSET_PORT`, `CONDUCTOR_PORT`, then deterministic or default allocation. Port inputs must be decimal base ports from `1` through `65526` so the complete 10-port block stays within `1-65535`; leading zeroes are normalized. Invalid values fail before starting processes, and an explicit `WORKSPACE_PORT` already overlapping another Git worktree's block fails instead of silently moving or sharing it. `bin/workspace info` reports the resolved block.

`run` and `archive` verify port release after sending TERM, within a five-second
inspection/wait budget. They do not force-kill or chase replacement processes.
On failure, run stops before startup; archive stops before database cleanup and
keeps any cleanup registration. Inspect the reported processes in their owning
app or terminal before retrying. TCP clients are excluded; local UDP sockets are
included. Port occupancy is not proof of checkout ownership, and OS permissions
can limit inspection. This does not prevent orphaning or supervise Foreman.

## Project application URL

For a project hostname shared by `info` and `run` using Workspace's resolved port, set
`WORKSPACE_APP_URL_TEMPLATE='https://app.example.localhost:{port}'` in `.env`.
Only the literal `{port}` is replaced; no template code executes. A complete
`WORKSPACE_APP_URL` takes precedence. Since `.env` is shared across siblings, put
a complete URL there only when all siblings should display that same fixed address,
not an address containing one workspace's allocated port.
Existing run-hook overrides remain supported but affect only `run`; remove redundant
URL assignments from that hook when adopting the shared template. Conflicting hook
assignments can make `info` and `run` display different addresses. `info` does not
run startup hooks or reserve ports; its port may be provisional before setup/run.
It also cannot see application-port overrides made by a run hook.
This configures the displayed address, not the web server or certificates.

## Reference

- Source: <https://github.com/jnunemaker/workspace>
- Local install: `~/.workspace` (CLI in `~/.workspace/bin/workspace`, lib scripts in `~/.workspace/lib/`)
- Environment: `WORKSPACE_HOME` (install location), `WORKSPACE_PORT` (optional base-port override), `SUPERCONDUCTOR_PORT` / `SUPERSET_PORT` / `CONDUCTOR_PORT` (provider-assigned base ports), `WORKSPACE_DB_SUFFIX` (exported during bootstrap/run), `WORKSPACE_ROOT_PATH` (resolved path to the original checkout; guaranteed to be available to the database hook when it names an existing directory), `WORKSPACE_APP_URL_TEMPLATE` (shared display address with a literal `{port}` placeholder), `WORKSPACE_APP_URL` (complete display address overriding the template; legacy run-hook assignments affect only `run`)
