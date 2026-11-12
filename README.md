# Rsync Deploy with Releases and Rollback

[English](README.md) | [简体中文](README.zh-CN.md)

Fast incremental `rsync` deployment over SSH, with independent releases, atomic `current` switching, rollback hooks, and persistent shared files. **Rsync Deploy with Releases and Rollback** deploys prebuilt files; it does not build your application.

This Action is published from [`sanwv/deploy-action`](https://github.com/sanwv/deploy-action).

## Features

- Release-based deployments with `current`, `releases/`, and `shared/` directories.
- Atomic activation by switching the `current` symlink.
- Configurable release retention for rollback.
- Persistent shared files and directories, with optional file initialization or synchronization.
- Shared item permissions configured per path.
- Bash, SSH, and rsync based; no Ansible or application build system required.

## How it works

The `target` input is the deployment root. The Action manages this structure:

```text
/srv/www/my-site/
├── current -> releases/<release-id>
├── releases/
│   ├── <release-id>/
│   └── ...
└── shared/
```

Each run uploads `source` to a new release directory. Once the release is ready, the Action atomically updates `current` and prunes old releases according to `releases_to_keep`. Configure the web server document root to use `target/current`.

For incremental deployments, the Action keeps a complete project copy in `target/shared/.shared-copy/`. Rsync checks file contents against this copy and transfers only differences; after synchronization, it copies the cache into the new release while holding a remote `flock` lock. Releases have independent files, so editing an old release cannot change a new one. The first deployment has no cache and uploads the full tree. `.shared-copy` is reserved and cannot be declared in `shared_items`; it uses roughly one extra project copy of disk space. Activation and pruning are also serialized with `flock`.

Before the symlink switch, a failed deployment leaves `current` pointing to the previous release. For an atomic switch, `target/current` and `target/releases` must be on the same filesystem.

## Quick start

In your repository, open **Settings → Secrets and variables → Actions** and add:

| Name | Type | Description |
|---|---|---|
| `SSH_PRIVATE_KEY` | Secret | Private key authorized to log in to the deployment server. |
| `SSH_KNOWN_HOSTS` | Optional secret or variable | Verified host key for the deployment server, in `known_hosts` format. If omitted, SSH uses `accept-new` and saves the first key in the runner's user known_hosts file. |
| `REMOTE_HOST` | Variable | Server hostname or IP address. |
| `REMOTE_USER` | Variable | SSH login user. |
| `REMOTE_PORT` | Optional variable | SSH port. Defaults to `22`. |

When configured, verify the server host key through a trusted channel before adding it; the Action then requires an exact match. When omitted, SSH accepts and stores a previously unseen key, while still rejecting a changed key already in known_hosts.

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy static site

on:
  push:
    branches: [main]

concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build site
        run: |
          npm ci
          npm run build

      - name: Deploy
        uses: sanwv/deploy-action@v1
        with:
          ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
          # Optional: without this input, SSH uses StrictHostKeyChecking=accept-new.
          ssh_known_hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
          remote_host: ${{ vars.REMOTE_HOST }}
          remote_user: ${{ vars.REMOTE_USER }}
          remote_port: ${{ vars.REMOTE_PORT }}
          source: ./dist
          target: /srv/www/my-site
          releases_to_keep: 5
```

`source` is a directory on the runner. Relative paths are resolved from `GITHUB_WORKSPACE`. Its contents are copied to the root of the release; for example, `./dist/index.html` becomes `current/index.html`.

`target` is the deployment root, not the `current` directory. The SSH user must be able to create directories and symlinks there, set permissions, and remove old releases.

## Shared files and directories

Use `shared_items` for data that must persist across releases, such as user uploads or runtime configuration. The input is a multiline string: one item per line, with comma-separated `key=value` fields.

```yaml
      - name: Deploy
        uses: sanwv/deploy-action@v1
        with:
          # Other required inputs omitted for brevity.
          shared_items: |
            type=directory,path=uploads,mode=775
            type=file,path=config/runtime.json,mode=664,from=config/runtime.example.json,sync=if-missing
            type=file,path=assets/managed-manifest.json,mode=644,from=shared-seed/manifest.json,sync=always
            type=file,path=data/runtime.json,sync=never
```

| Field | Required | Applies to | Description |
|---|---:|---|---|
| `type` | Yes | Both | `directory` or `file`. |
| `path` | Yes | Both | Path relative to the remote `target/shared/` directory. |
| `mode` | No | Both | Octal permissions, such as `775` for a directory or `664` for a file. |
| `from` | Conditional | Files | Source file path relative to the project root (`GITHUB_WORKSPACE`). |
| `sync` | No | Files | `never`, `if-missing`, or `always`. Defaults to `never`. |

### Shared directory

```text
type=directory,path=uploads,mode=775
```

The Action creates `target/shared/uploads` and replaces `uploads` in each release with a symlink to it. The directory persists across deployments and is not synchronized from the build output.

### Initialize a shared file once

```text
type=file,path=config/runtime.json,mode=664,from=config/runtime.example.json,sync=if-missing
```

The Action creates the parent directory under `target/shared/`. If `target/shared/config/runtime.json` does not exist, it initializes the file from `GITHUB_WORKSPACE/config/runtime.example.json`. If the shared file already exists, it is preserved. Each release links `config/runtime.json` to the shared file.

The shared `from` path is relative to the **project root (`GITHUB_WORKSPACE`)**, not to the top-level `source` build directory. For example, with `source: ./dist`, `from: config/runtime.example.json` refers to `./config/runtime.example.json` at the repository root.

The Action does not create an empty shared file. If `from` is omitted or `sync=never` is used, create the file on the server or have your application/initialization process create it.

### Synchronize a shared file on every deployment

```text
type=file,path=assets/managed-manifest.json,mode=644,from=shared-seed/manifest.json,sync=always
```

On each deployment, the Action updates the shared file from `GITHUB_WORKSPACE/shared-seed/manifest.json`. It uploads to a temporary file and then atomically replaces the target file.

`always` updates a file shared by all releases. The shared file may therefore change even if a deployment later fails before switching `current`. Use this mode only for repository-managed data that may be updated across releases. Keep configuration that must match a specific code release inside that release instead.

### Shared item rules

- `path` is relative to `target/shared/`; it must not start with `/` or contain a `..` path component.
- `from` is relative to `GITHUB_WORKSPACE` and must not escape the project root.
- Directory items do not accept `from` or `sync`.
- File items using `if-missing` or `always` must specify `from`.
- Values cannot contain commas or equals signs. Use one item per line.
- `mode` accepts three- or four-digit octal values.
- The Action sets permissions with `chmod`; ownership and group membership must be configured on the server. It does not run `chown`.

## Inputs

| Input | Required | Default | Description |
|---|---:|---:|---|
| `ssh_private_key` | Yes | — | SSH private key. Pass it as a GitHub Secret. |
| `ssh_known_hosts` | No | Empty | Verified SSH host key. If empty, SSH accepts and records new host keys (`accept-new`). |
| `remote_host` | Yes | — | Remote hostname or IP address. |
| `remote_user` | Yes | — | SSH login user. |
| `source` | Yes | — | Prebuilt files directory on the runner. |
| `target` | Yes | — | Remote deployment root directory. |
| `remote_port` | No | `22` | SSH port. |
| `releases_to_keep` | No | `5` | Number of releases to retain after deployment (`1`–`100`). The active release is always retained. |
| `shared_items` | No | Empty | Shared paths, permissions, and file synchronization rules. |
| `script_before` | No | Empty | Bash script run remotely before creating a release. |
| `script_before_activate` | No | Empty | Bash script run remotely after release preparation and before switching `current`. |
| `script_after` | No | Empty | Bash script run remotely after switching `current` and before pruning old releases. Failure restores the previous `current`. |

### Remote deployment scripts

All three script inputs run as Bash on the deployment server. The scripts can use these environment variables:

| Variable | Meaning |
|---|---|
| `DEPLOY_TARGET` | Deployment root directory. |
| `DEPLOY_RELEASE_ID` | Release ID for this run. |
| `DEPLOY_RELEASE_PATH` | Absolute path to this release. |
| `DEPLOY_PREVIOUS_RELEASE` | Release previously referenced by `current`; empty on the first deployment. |
| `DEPLOY_HOOK` | Current phase: `before`, `before-activate`, or `after`. |

`script_before` runs after the remote base directories are prepared and before the release is created. Use it for disk-space, permission, or service checks. `script_before_activate` runs after synchronization and shared-link setup; its working directory is the candidate release. Either script failing aborts deployment while the previous release remains active.

`script_after` runs after switching `current`, from the new release directory. Old releases are pruned only after it succeeds. On failure, the Action atomically restores `current` to `DEPLOY_PREVIOUS_RELEASE` while holding the deployment lock, retains the old release, and fails the deployment. On a first deployment, it removes the newly created `current` link. External state such as database changes is not rolled back and must remain compatible with the previous release.

Builds, runner-side tests, and public health checks can be ordinary workflow `run:` steps before or after this Action. A later local health-check failure does not automatically roll back the deployment.

## Requirements

- A Linux server accessible over SSH.
- `bash`, `rsync`, `flock`, and standard GNU/Linux utilities on the server.
- `bash`, OpenSSH, and `rsync` on the runner. The Action reports an error if a required command is missing.
- The SSH user must have sufficient permissions under `target`. The Action does not use `sudo`.
- Configure the web server document root to `target/current`.

## Troubleshooting

**SSH host-key verification fails**

Check that `SSH_KNOWN_HOSTS` contains the key for the host and port being used. Verify the key through a trusted channel.

**rsync or permission errors**

Confirm that rsync is installed on both the runner and server, and that `REMOTE_USER` can write to `TARGET`. The Action does not use `sudo`.

**The application cannot find a shared file**

`sync=never` does not create the file. Ensure the shared file already exists, or configure `from` relative to `GITHUB_WORKSPACE` and use `if-missing` or `always`.

**The site still serves the previous version**

Check that the web server document root points to `TARGET/current`, not to a fixed `releases/<release-id>` directory.
