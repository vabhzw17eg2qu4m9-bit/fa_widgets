# Schema reference

## Three widget kinds

A `widgets/<id>/` folder is one of:

- **LOCAL** — `manifest.json` + `widget.js` (+ assets) all live here.
  Used for widgets calling Fa-specific APIs (`jsr.fa.*`) and conscious
  forks (e.g. `fitness-trainer` with its install-dir GLB, `yolo-hello`
  branding).
- **VENDORED** — `overlay.json` + `icon.svg` only; the code and the base
  `manifest.json` come from the `vendor/js_widget_runtime` submodule
  (`example/widgets/<id>/`, single source of truth). The merged manifest
  (base + overlay) is what validation, zips and `catalog.json` see.
- **EXTERNAL** — `overlay.json` with a REQUIRED `source` block; the code
  and the base `manifest.json` come from a per-widget git submodule at
  `vendor/external/<id>/` — the author's own PUBLIC GitHub repo, pinned
  at `source.commit`. This is how widgets published from the Fa app
  arrive (the app pushes the widget to the user's repo and opens the PR
  with the overlay + submodule pin).

### `widgets/<id>/overlay.json` (vendored and external)

| field | required | notes |
|-------|----------|-------|
| `icon` | yes (file must exist locally, or in the user repo for EXTERNAL) | path inside the widget folder |
| `tags` | – | free-form, lowercased by CI |
| `author` | – | defaults from the base manifest |
| `minRuntime` | yes | runtime floor, strict semver |
| `description` | – | overrides the base description |
| `source` | **EXTERNAL: yes** — forbidden for VENDORED | `{"repo": "owner/name", "commit": "<40-hex sha>"}` |

Any other key — especially `version` or `id` — is a validation ERROR:
those are single-sourced from the submodule manifest.

### EXTERNAL rules

- `source.repo` must be a GitHub `owner/name` slug
  (`[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+`); the repo MUST be public — catalog
  CI clones external submodules anonymously.
- `source.commit` must be a full 40-hex sha; the
  `vendor/external/<id>/` submodule HEAD must equal it exactly (drift =
  validation error — re-pin the submodule and update the overlay).
- The submodule must be registered in the ROOT `.gitmodules` with
  `path = vendor/external/<id>` and a url pointing at `source.repo`
  (https or ssh form, `.git` suffix optional).
- The repo holds a normal widget at its root: `manifest.json` (same
  rules as a vendored CORE base manifest — `id` must equal the catalog
  folder name) plus `widget.js` or the manifest-declared live-tile entry
  (`widget.entry`). Version/id/permissions come from THAT manifest; the
  overlay carries catalog meta only.

Example:

```json
{
  "icon": "icon.svg",
  "tags": ["pomodoro"],
  "author": "Octocat",
  "minRuntime": "0.4.89",
  "source": {"repo": "octocat/fa-widget-focus", "commit": "637c99a7909c70910ddcd0600d81d9a4f741c1ba"}
}
```

The generated catalog entry carries the `source` block through (so the
Fa app can link the origin repo), and preview URLs point at
`raw.githubusercontent.com/<repo>/<commit>/…`.

## `widgets/<id>/manifest.json`

Runtime fields (consumed by the Fa app) + catalog metadata. Unknown keys are
warnings — schema evolves additively.

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `id` | string | ✔ | `[a-z0-9][a-z0-9-]{1,31}`, MUST equal folder name |
| `name` | string | ✔ | human title |
| `description` | string | – | shown in gallery (missing → warning) |
| `version` | string | ✔ | strict semver `X.Y.Z` |
| `icon` | string | – | relative path, existing file (`.svg` recommended) |
| `author` | string | – | display credit |
| `tags` | list<string> | – | free-form, lowercased by CI |
| `platforms` | list<string> | – | OS targets: `ios`, `macos`, `android`, `windows`, `linux`, `web`; omit for runs-everywhere widgets. Unknown values → warning; mirrored into the catalog entry |
| `minRuntime` | string | ✔ | minimum `js_widget_runtime` version, e.g. `0.4.79` |
| `license` | string | – | defaults to repo MIT |
| `network` | bool | ✔ | `jsr.fetchJson` gate |
| `allowedCommands` | list<string> | ✔ | `jsr.exec` allowlist (runtime prompts regardless) |
| `permissions.*` | key/value | – | service gates: `llm`, `homekit`, `health`, `contacts`, `calendar`, `microphone`, `notifications`, `media`, `keys` |
| `widget` | object | – | live tile: `{entry, size: 'WxH', refreshSeconds, interactive}` — `interactive: true` routes tile taps to `jsr.onEvent` on the board instead of opening the app |

## Generated `catalog.json` entry

```json
{
  "id": "...", "name": "...", "version": "1.0.0",
  "description": "...", "author": "...", "tags": [],
  "platforms": ["ios", "macos"], // only when the manifest declares it
  "permissions": {"network": false, "allowedCommands": []},
  "minRuntime": "0.4.79", "icon": "icon.svg",
  "zip": {"file": "<id>-<version>.zip", "sha256": "<hex>", "sizeBytes": 1234}
}
```

Top level: `schemaVersion: 1`, `generatedAt` (UTC ISO-8601),
`sourceRepo`. Widgets sorted by `id`. Additive evolution only within
schemaVersion 1.

## Zip layout

Single root folder `<id>/` containing every file of the widget directory;
entries sorted by path; deflate. Consumers join asset names against
`https://github.com/IstiN/fa_widgets/releases/latest/download/`.
es sorted by path; deflate. Consumers join asset names against
`https://github.com/IstiN/fa_widgets/releases/latest/download/`.
