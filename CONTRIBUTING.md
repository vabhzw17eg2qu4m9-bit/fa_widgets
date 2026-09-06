# Contributing

PRs welcome! Everything happens through review: direct pushes to `main` skip
validation only on paper — publish still re-validates and fails loudly.

## Quick start

```sh
git clone git@github.com:IstiN/fa_widgets.git && cd fa_widgets
git submodule update --init                  # vendored CORE widget sources
dart pub get
dart run bin/fa_widgets.dart validate        # must exit 0
dart run bin/fa_widgets.dart catalog --out build/catalog
```

## Local or vendored?

- Widget calls **Fa-specific APIs** (`jsr.fa.*`) or is a conscious fork →
  LOCAL: `manifest.json` + `widget.js` here, as below.
- Widget uses **only the portable `jsr` API** → it belongs to the runtime
  repo (`flutter_js_widget_runtime/example/widgets/`); here it becomes
  VENDORED: `overlay.json` + `icon.svg` (see `docs/schema.md` and
  `README.md` → "Vendored (CORE) widgets"). Do not copy the code.

## Publishing from the Fa app

You don't have to hand-author any of this: build the widget in the Fa app,
connect GitHub once (Settings → GitHub account), then long-press the widget
→ **Publish**. The app pushes the sources to a public repo under YOUR
account, forks this catalog, and opens the PR for you — an EXTERNAL widget:
`widgets/<id>/overlay.json` with a `source: {repo, commit}` pin plus the
`vendor/external/<id>/` submodule (see `docs/schema.md`). Review and merge
stay manual; the PR's status and reviewer comments show up in the app.

## Authoring checklist

- [ ] Folder `widgets/<id>/`, lowercase-hyphen id == folder name.
- [ ] `manifest.json` per `docs/schema.md`; bump `version` on every change.
- [ ] `widget.js` renders through `jsr.render`, registers `jsr.onEvent`,
      calls `jsr.exportState` (so agent snapshots stay useful).
- [ ] Works on dark theme (hardcoded palettes like the samples are fine,
      or read `jsr.theme`).
- [ ] Declare honestly what you use: `network: true`, `allowedCommands`,
      service permission keys (`contacts`, `calendar`, ...). Undeclared
      capability use = rejected. All permissions are runtime-gated anyway.
- [ ] Icon `icon.svg` present, legible at small sizes on dark backgrounds.

## Code style

Tooling (this package): single quotes, package-relative imports, keep files
small, `dart analyze`/`dart test` green. Widgets: plain ES2019-compatible JS
(no imports/bare specifiers — multi-file needs go through relative inlining
per the js_widget_runtime loader), no external CDNs unless `network: true`.

## Releasing

Nothing manual: merge to `main` rebuilds the rolling `catalog` release and
tags any bumped widget versions.
