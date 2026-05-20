# O3P Module Install Script

Shared installer for Odoo third-party modules.

This repository contains the install system used by O3P modules. It can also be used for any Odoo module that lives in a Git repository, as long as the module provides a small `.o3p.json` file describing what should be installed.

The v2 entrypoint is:

```bash
sources/run.sh
```

It is designed to be run directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/odoo-third-party/o3p-module-install-script/main/sources/run.sh \
  | bash -s -- --config "https://raw.githubusercontent.com/odoo-third-party/o3p-future-module/main/o3p-future-module.o3p.json"
```

## What It Does

The installer reads a JSON config, discovers local Odoo installations, chooses the target instance, finds the correct addons directory, clones the requested Git repositories, copies the module folders, and optionally restarts Odoo and refreshes the app list.

It supports:

- one or many modules in the same config file
- local config files or `http://` / `https://` config URLs
- multiple Odoo instances on the same server
- Odoo running under systemd
- Odoo running in Docker containers
- different Odoo versions on different instances
- automatic branch selection based on the selected Odoo version
- addons-directory detection from Odoo process args, config files, logs, and common paths
- dry runs for checking what would happen before changing anything

## Requirements

Required:

- Bash
- `jq`
- `git`

Required only for URL configs:

- `curl`

Required only for Docker-managed Odoo instances:

- Docker CLI access

## Config Format

A config file usually ends in `.o3p.json`, but any JSON file path or URL can be passed with `--config`.

Minimal example:

```json
{
  "schema_version": 2,
  "modules": [
    {
      "name": "first_addon",
      "github_repository": "https://github.com/example/first-addon"
    },
    {
      "name": "second_addon",
      "github_repository": "https://github.com/example/second-addon"
    }
  ]
}
```

Each module must define:

- `name`: the Odoo technical module name.
- `github_repository`: the Git repository URL to clone.

The installer also accepts these aliases for `github_repository`: `github`, `repo`, `repository`, and `github repository`.

Module folder and branch rules:

There are no optional per-module install-path fields. The module name, the addon folder inside the repository, and the destination folder inside the Odoo addons directory must be the same value.

Branch selection is always automatic. The installer tries the selected Odoo version branch first, then `main`, then `master`.

Fuller example:

```json
{
  "schema_version": 2,
  "name": "Example module package",
  "database": "my_odoo_database",
  "odoo": {
    "selector": "auto",
    "addons_dir": ""
  },
  "install": {
    "restart": true,
    "refresh_apps": true
  },
  "modules": [
    {
      "name": "my_addon",
      "github_repository": "https://github.com/example/my-addon"
    }
  ]
}
```

See [sources/CONFIG_SCHEMA.md](sources/CONFIG_SCHEMA.md) and [sources/example.o3p.json](sources/example.o3p.json).

## Usage

Install from a local config:

```bash
./sources/run.sh --config ./my-module.o3p.json
```

Install from a remote config:

```bash
curl -fsSL https://raw.githubusercontent.com/odoo-third-party/o3p-module-install-script/main/sources/run.sh \
  | bash -s -- --config "https://raw.githubusercontent.com/example/my-addon/main/my-addon.o3p.json"
```

Preview without copying, restarting, or refreshing:

```bash
./sources/run.sh --config ./my-module.o3p.json --dry-run --no-restart --no-refresh
```

Install into a specific discovered instance:

```bash
./sources/run.sh --config ./my-module.o3p.json --instance 2
```

Install into all discovered instances:

```bash
./sources/run.sh --config ./my-module.o3p.json --all
```

Replace existing addon folders without prompting:

```bash
./sources/run.sh --config ./my-module.o3p.json --force
```

Refresh a specific database after copying:

```bash
./sources/run.sh --config ./my-module.o3p.json --database my_odoo_database
```

## Instance Selection

When multiple Odoo instances are found, the installer can select one in several ways:

- `auto`: choose automatically, or prompt when running interactively.
- `all`: install into every discovered instance.
- `1`, `2`, `3`: choose by the numbered discovery list.
- `pid:1234`: choose by process id.
- `container:odoo17`: choose by Docker container id or name.

Example:

```bash
./sources/run.sh --config ./my-module.o3p.json --instance container:odoo17
```

## Addons Directory Detection

The installer first chooses the target Odoo instance, then finds the addons directory for that instance. This matters on servers that run multiple Odoo versions or multiple containers.

Detection uses several signals:

- explicit `--addons-dir`
- `odoo.addons_dir` from the JSON config
- Odoo process arguments such as `--addons-path`
- Odoo config files such as `/etc/odoo.conf`
- Odoo logs, including `addons paths` lines
- module loading evidence in logs, such as paths ending in `base/__manifest__.py`
- common Odoo filesystem locations
- Docker bind mounts, when installing into containers

## CLI Options

```text
--config FILE_OR_URL     Required. Local .o3p.json file or http/https URL.
--instance SELECTOR      auto, all, a 1-based list number, pid:PID, or container:ID.
--all                    Install into every discovered Odoo instance.
--database DB            Override the database from the .o3p.json file.
--addons-dir PATH        Override addons directory detection.
--force                  Replace existing target addon directories without prompting.
--yes                    Accept non-destructive prompts.
--non-interactive        Never prompt; auto-select the highest confidence instance.
--dry-run                Show discovery and planned actions without copying/restarting.
--no-restart             Do not restart Odoo after copying modules.
--no-refresh             Do not refresh Odoo app lists, even when database is known.
--keep-workdir           Keep temporary files for debugging.
-h, --help               Show help.
```

## For Module Authors

To make a Git-hosted module installable with this system:

1. Add a `.o3p.json` file to your module repository.
2. Include a `modules` list with at least `name` and `github_repository`.
3. Publish an install command that pipes this repository's `sources/run.sh` and passes your raw JSON URL.

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/odoo-third-party/o3p-module-install-script/main/sources/run.sh \
  | bash -s -- --config "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/YOUR_MODULE.o3p.json"
```

This project is maintained as a generic installer: O3P modules use it by default, but it is not limited to O3P modules.
