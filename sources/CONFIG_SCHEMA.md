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

Optional per module:

- `branch`: branch to clone. Use `auto` or omit it to try the selected Odoo version branch first, then `main`, then `master`.
- `path`: addon folder inside the cloned repository. Defaults to `name`.
- `destination_name`: folder name to copy into the addons directory. Defaults to `name`.
- `legacy_names`: older addon folder names to reject or remove when `--force` is used.

Optional package fields:

- `database`: database to refresh after copy.
- `odoo.selector`: `auto`, `all`, a discovered instance number, `pid:PID`, or `container:ID_OR_NAME`.
- `odoo.addons_dir`: explicit addons directory override.
- `install.force`: replace existing addon folders.
- `install.restart`: restart the selected Odoo after copy.
- `install.refresh_apps`: refresh app list and upgrade already-installed modules.
