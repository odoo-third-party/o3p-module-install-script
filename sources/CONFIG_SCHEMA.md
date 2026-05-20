# O3P config schema v2

The installer reads a JSON file passed with `--config`. The file can be local or an `http://` / `https://` URL.

Minimal module list:

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

Required per module:

- `name`: Odoo technical module name.
- `github_repository`: Git repository URL to clone.

Accepted aliases for `github_repository` are `github`, `repo`, `repository`, and `github repository`.

The module name, addon folder inside the repository, and destination folder inside the Odoo addons directory are the same value. Branch selection is always automatic: the installer tries the selected Odoo version branch first, then `main`, then `master`.

Optional package fields:

- `database`: database to refresh after copy.
- `odoo.selector`: `auto`, `all`, a discovered instance number, `pid:PID`, or `container:ID_OR_NAME`.
- `odoo.addons_dir`: explicit addons directory override.
- `install.restart`: restart the selected Odoo after copy.
- `install.refresh_apps`: refresh app list and upgrade already-installed modules.
