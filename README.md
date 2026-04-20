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
| `init`      | Set up a project for workspace support (database.yml, conductor, superset configs) |
| `bootstrap` | Set up a workspace — symlink shared files, run app setup, create isolated DBs |
| `run`       | Start the dev server for this workspace                         |
| `archive`   | Tear down a workspace — kill processes, drop DBs                |
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

## Environment

- `WORKSPACE_HOME` — install location (default `~/.workspace`)
- `WORKSPACE_DB_SUFFIX` — exported during bootstrap/run as `_<workspace-name>`, used by the database.yml patch

## Tests

```sh
test/run_tests.sh
```
