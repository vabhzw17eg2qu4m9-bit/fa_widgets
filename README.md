# fa_widgets

The Fa widget catalog: a curated collection of JavaScript widgets for the
[Fa app](https://fa1.dev) and its agent. Widgets are small apps written
against [`js_widget_runtime`](https://pub.dev/packages/js_widget_runtime) —
a `jsr`-object API rendered as native Flutter UI (JSON UI tree + event
handler), running inside Fa's own JS engine with per-permission gating
(network, commands, system services — all default denied).

This repo holds **sources only**. Release artifacts (per-widget zips +
`catalog.json`) are built by CI and published to a rolling GitHub release:

```
https://github.com/IstiN/fa_widgets/releases/latest/download/catalog.json
https://github.com/IstiN/fa_widgets/releases/latest/download/<id>-<version>.zip
```

Version-bumped widgets also get immutable tags `<id>-v<version>` with the zip
attached — stable permalinks and rollback points.

## Layout

```
widgets/<id>/            one folder per widget, three kinds:
    manifest.json + widget.js   LOCAL widgets (Fa-specific APIs, forks)
    overlay.json + icon.svg     VENDORED widgets — code + base manifest live in
                                the runtime repo (single source of truth)
    overlay.json with source    EXTERNAL widgets — code + manifest live in the
                                author's public repo, vendored as a per-widget
                                submodule (published from the Fa app)
vendor/js_widget_runtime   git submodule: flutter_js_widget_runtime (CORE sources)
vendor/external/<id>       git submodules: one per EXTERNAL widget (user repos)
lib/, bin/, test/          the Dart tooling that validates and packages the catalog
docs/                      schema notes
.github/workflows/         validate.yml (PRs) · publish.yml (rolling release)
```

### Vendored (CORE) widgets

Widgets that use only the portable `jsr` API are **single-sourced** from
[`flutter_js_widget_runtime`](https://github.com/IstiN/flutter_js_widget_runtime)
(`example/widgets/<id>/`), vendored here as a git submodule. This repo adds
only catalog meta in `widgets/<id>/overlay.json`:

```json
{
  "icon": "icon.svg",
  "tags": ["demo"],
  "author": "Fa",
  "minRuntime": "0.4.89",
  "description": "optional override"
}
```

`version`/`id`/runtime flags (`network`, `allowedCommands`, …) are FORBIDDEN
in the overlay — they come from the submodule manifest so the two repos
cannot drift (validator errors otherwise). Syncing = bumping the submodule
pin (`git submodule update --remote vendor/js_widget_runtime` on a fresh
runtime release tag) + push; CI rebuilds the changed zips. After cloning,
run `git submodule update --init` once.

### External (user) widgets

Widgets published from the Fa app live in the AUTHOR's own public GitHub
repo and arrive here as EXTERNAL widgets: `widgets/<id>/overlay.json`
carries a required `source: {"repo": "owner/name", "commit": "<sha>"}`
block and the code is pinned as a per-widget submodule at
`vendor/external/<id>/` (registered in `.gitmodules`). Same
single-source rule as CORE — version/id/permissions come from the widget's
own `manifest.json` inside the submodule, the overlay is catalog meta only.
The repo must be PUBLIC: catalog CI clones external submodules anonymously.

## Contributing a widget

1. Fork / branch, add `widgets/my-widget/`:
   - `manifest.json` — see `docs/schema.md` (id == folder name, semver,
     declared permissions).
   - `widget.js` — an IIFE using the `jsr` API (`jsr.render`,
     `jsr.onEvent`, `jsr.exportState`, ...). Look at `calculator` and
     `focus-timer` for reference patterns.
   - `icon.svg` — recommended, square, works on dark backgrounds.
2. Run locally:
   ```
   dart pub get
   dart run bin/fa_widgets.dart validate
   dart run bin/fa_widgets.dart catalog --out build/catalog   # optional dry run
   ```
3. Open a PR — CI validates. On merge to `main` the catalog release is
   rebuilt automatically; your widget appears in Fa's Plugins gallery and on
   https://fa1.dev/widgets without any further steps.

Bump `version` in the manifest for every change of content — CI detects bumps
and cuts per-widget release tags.

## For maintainers

Publishing is fully automated on push to `main`
(`.github/workflows/publish.yml`): validate → build zips → diff against the
current published catalog → tag bumped widgets → refresh the rolling
`catalog` release with `--clobber`. Requires only the default `GITHUB_TOKEN`.

## License

MIT — see [LICENSE](LICENSE).
