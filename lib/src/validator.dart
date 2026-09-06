import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'issues.dart';
import 'manifest.dart';

/// Upper bounds producing warnings (not errors) so oversized submissions
/// still pass local validation but get flagged in review.
const sizeWarnBytes = 5 * 1024 * 1024;
const fileCountWarn = 50;

/// Platforms the Fa app targets. Values outside this set warn (not error)
/// so new platforms can roll out additively.
const knownPlatforms = <String>{
  'ios',
  'macos',
  'android',
  'windows',
  'linux',
  'web',
};

/// Result of scanning one `widgets/<id>/` directory.
final class WidgetValidation {
  WidgetValidation._(
    this.directory,
    this.manifest,
    this.errors,
    this.warnings,
    this.sourceFiles,
    this.externalSource,
  );

  /// The widget directory that was scanned.
  final Directory directory;

  /// Parsed manifest, or null when it could not be parsed at all. For
  /// vendored widgets this is the MERGE of the vendor base manifest and
  /// the local overlay meta.
  final WidgetManifest? manifest;

  final List<ValidationError> errors;
  final List<ValidationWarning> warnings;

  /// The files that make up the publishable widget (zip content), as
  /// `(path-in-widget, bytes)` pairs: the widget directory's own files for
  /// LOCAL widgets, or vendor code + synthesized merged manifest + local
  /// icon for VENDORED/EXTERNAL ones. Null when validation failed before
  /// source resolution.
  final List<({String path, List<int> bytes})>? sourceFiles;

  /// The parsed `source` block when this is an EXTERNAL widget (code lives
  /// in the user-repo submodule `vendor/external/<id>/`); null for LOCAL
  /// and VENDORED widgets.
  final ExternalSource? externalSource;

  /// True when publishing may proceed.
  bool get isValid => errors.isEmpty;

  /// All issues, errors first.
  List<ValidationIssue> get issues => [...errors, ...warnings];
}

/// Overlay keys allowed in a vendored widget's `overlay.json` — catalog
/// meta ONLY. `version`/`id`/runtime flags are single-sourced from the
/// vendor base manifest so the two repos cannot drift structurally.
const allowedOverlayKeys = <String>{
  'icon',
  'tags',
  'author',
  'minRuntime',
  'description',
};

/// Overlay keys allowed in an EXTERNAL widget's `overlay.json`: the
/// vendored catalog-meta allowlist plus the REQUIRED `source` block that
/// pins the user repo (`{"repo": "owner/name", "commit": "<40-hex sha>"}`).
const allowedExternalOverlayKeys = <String>{
  ...allowedOverlayKeys,
  'source',
};

/// The parsed `source` block of an EXTERNAL overlay: where the widget's
/// code lives (a PUBLIC GitHub repo — catalog CI clones it anonymously)
/// and the exact commit the `vendor/external/<id>` submodule is pinned at.
final class ExternalSource {
  ExternalSource({required this.repo, required this.commit});

  /// `owner/name` of the user's public GitHub repo.
  final String repo;

  /// Full 40-hex commit sha the submodule must be pinned at.
  final String commit;
}

/// Validates one widget directory against the rules in
/// `docs/schema.md`. Never throws for content problems — everything lands
/// in [WidgetValidation.errors]/[warnings]; only a missing directory throws
/// ([FileSystemException] via listSync).
///
/// A directory holding `overlay.json` instead of `manifest.json` is a
/// VENDORED widget: its code + base manifest live in
/// `vendor/js_widget_runtime/example/widgets/<id>/` (the git submodule —
/// single source of truth), while the overlay carries catalog meta
/// ([allowedOverlayKeys]). [vendorRoot] points at the submodule checkout;
/// it defaults to `../vendor/js_widget_runtime` relative to the widgets
/// root's parent when validating through [validateWidgetsRoot].
///
/// An overlay with a `source` block is an EXTERNAL widget instead: the
/// code + base manifest live in the per-widget submodule
/// `vendor/external/<id>/` (the user's public repo, pinned at
/// `source.commit`) under [repoRoot] — which defaults to the widgets
/// root's parent, i.e. `<dir>/../../`.
WidgetValidation validateWidgetDirectory(
  Directory dir, {
  Directory? vendorRoot,
  Directory? repoRoot,
}) {
  final errors = <ValidationError>[];
  final warnings = <ValidationWarning>[];
  final id = p.basename(dir.path);

  void error(String message) => errors.add(ValidationError('$id: $message'));

  final overlayFile = File('${dir.path}/overlay.json');
  final manifestFile = File('${dir.path}/manifest.json');
  if (overlayFile.existsSync() && manifestFile.existsSync()) {
    error(
      'both overlay.json and manifest.json present — a widget is either '
      'vendored (overlay.json, code in the submodule) or local '
      '(manifest.json + widget.js), never both',
    );
    return WidgetValidation._(dir, null, errors, warnings, null, null);
  }
  if (overlayFile.existsSync()) {
    return _validateOverlayWidget(
      dir,
      overlayFile,
      vendorRoot: vendorRoot,
      repoRoot: repoRoot ?? Directory(p.dirname(p.dirname(dir.path))),
    );
  }
  return _validateLocalWidget(dir, manifestFile);
}

/// The classic path: `manifest.json` + `widget.js` (+ assets) all live in
/// the widget directory (FA-specific and forked widgets).
WidgetValidation _validateLocalWidget(Directory dir, File manifestFile) {
  final errors = <ValidationError>[];
  final warnings = <ValidationWarning>[];
  final id = p.basename(dir.path);

  void error(String message) => errors.add(ValidationError('$id: $message'));
  void warn(String message) => warnings.add(ValidationWarning('$id: $message'));

  WidgetManifest? manifest;
  if (!manifestFile.existsSync()) {
    error('missing manifest.json (or overlay.json for a vendored widget)');
    return WidgetValidation._(dir, null, errors, warnings, null, null);
  }
  String manifestText;
  try {
    manifestText = manifestFile.readAsStringSync();
  } on FileSystemException catch (e) {
    error('manifest.json unreadable: ${e.message}');
    return WidgetValidation._(dir, null, errors, warnings, null, null);
  }
  try {
    manifest = WidgetManifest.decode(manifestText);
  } on FormatException catch (e) {
    error('manifest.json is not valid JSON: ${e.message}');
    return WidgetValidation._(dir, null, errors, warnings, null, null);
  } on ManifestException catch (e) {
    for (final message in e.errors) {
      error('manifest.json: $message');
    }
    return WidgetValidation._(dir, null, errors, warnings, null, null);
  }

  // ── id / folder identity ────────────────────────────────────────────────
  final idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,31}$');
  if (!idPattern.hasMatch(manifest.id)) {
    error(
      "manifest id '${manifest.id}' must match "
      '[a-z0-9][a-z0-9-]{1,31}',
    );
  }
  if (manifest.id != id) {
    error(
      "manifest id '${manifest.id}' must equal the folder name '$id'",
    );
  }

  // ── version ─────────────────────────────────────────────────────────────
  if (!isValidSemver(manifest.version)) {
    error("version '${manifest.version}' must be strict semver X.Y.Z");
  }

  // ── minRuntime ──────────────────────────────────────────────────────────
  _validateMinRuntime(manifest, error);

  // ── network / allowedCommands types ─────────────────────────────────────
  _validateRuntimeFlags(manifest, error);

  // ── platforms shape / known values (warnings) ───────────────────────────
  _validatePlatforms(manifest, warn);

  // ── entry + icon files ──────────────────────────────────────────────────
  final entry = File('${dir.path}/widget.js');
  if (!entry.existsSync()) {
    error('missing widget.js entry');
  } else {
    final bytes = entry.readAsBytesSync();
    if (bytes.isEmpty) {
      error('widget.js is empty');
    } else if (bytes.length > 1024 * 1024) {
      warn('widget.js larger than 1 MiB');
    }
  }
  _validateIcon(dir, manifest, error, warn);

  // ── size / file-count budget (warnings) ─────────────────────────────────
  final files = dir.listSync(recursive: true).whereType<File>().toList();
  _validateBudget(files, warn);

  // ── presence of description (warning only) ──────────────────────────────
  if (manifest.description.isEmpty) warn('no description');

  // ── unknown keys (warning; additive schema evolution) ───────────────────
  for (final key in manifest.raw.keys) {
    if (!knownManifestKeys.contains(key)) {
      warn("unknown manifest key '$key' (forward-compat: ignored by CI)");
    }
  }

  return WidgetValidation._(
    dir,
    manifest,
    errors,
    warnings,
    errors.isEmpty
        ? [
            for (final file in files)
              (
                path:
                    p.relative(file.path, from: dir.path).replaceAll('\\', '/'),
                bytes: file.readAsBytesSync(),
              ),
          ]
        : null,
    null,
  );
}

/// The overlay path: overlay meta + submodule code/manifest. Two flavours:
///
/// - VENDORED — code + base manifest come from the CORE runtime submodule
///   ([vendorRoot]/`example/widgets/<id>/`).
/// - EXTERNAL — the overlay carries a `source` block; code + base manifest
///   come from the per-widget user-repo submodule `vendor/external/<id>/`
///   under [repoRoot], pinned at exactly `source.commit`.
///
/// Everything past source resolution (lenient base-manifest parse, merge,
/// merged-manifest checks, zip source list) is shared so both kinds obey
/// the same single-source-of-truth rules.
WidgetValidation _validateOverlayWidget(
  Directory dir,
  File overlayFile, {
  required Directory? vendorRoot,
  required Directory repoRoot,
}) {
  final errors = <ValidationError>[];
  final warnings = <ValidationWarning>[];
  final id = p.basename(dir.path);

  void error(String message) => errors.add(ValidationError('$id: $message'));
  void warn(String message) => warnings.add(ValidationWarning('$id: $message'));

  WidgetValidation fail() =>
      WidgetValidation._(dir, null, errors, warnings, null, null);

  // ── overlay shape ───────────────────────────────────────────────────────
  Map<String, dynamic> overlay;
  try {
    final decoded = jsonDecode(overlayFile.readAsStringSync());
    if (decoded is! Map) {
      error('overlay.json must be a JSON object');
      return fail();
    }
    overlay = decoded.cast<String, dynamic>();
  } on FormatException catch (e) {
    error('overlay.json is not valid JSON: ${e.message}');
    return fail();
  }
  final isExternal = overlay.containsKey('source');
  final allowedKeys =
      isExternal ? allowedExternalOverlayKeys : allowedOverlayKeys;
  for (final key in overlay.keys) {
    if (!allowedKeys.contains(key)) {
      error(
        "overlay.json key '$key' is not allowed — "
        '${isExternal ? 'external' : 'vendored'} widgets may override only '
        '${allowedKeys.join(', ')}; version/id/runtime '
        'flags are single-sourced from the submodule manifest',
      );
    }
  }
  if (errors.isNotEmpty) {
    return fail();
  }

  // ── code source: CORE submodule (vendored) / user repo (external) ───────
  ExternalSource? externalSource;
  Directory codeDir;
  if (isExternal) {
    externalSource = _parseExternalSource(overlay['source'], error);
    if (externalSource == null) return fail();
    codeDir = Directory(p.join(repoRoot.path, 'vendor', 'external', id));
    if (!_validateExternalSubmodule(codeDir, externalSource, repoRoot, error)) {
      return fail();
    }
  } else {
    if (vendorRoot == null) {
      error(
        'vendored widget but no vendor submodule checkout '
        '(vendor/js_widget_runtime) — run: git submodule update --init',
      );
      return fail();
    }
    codeDir = Directory(p.join(vendorRoot.path, 'example', 'widgets', id));
  }
  // Message prefixes keep naming the historical 'vendor' source for
  // VENDORED widgets and 'external' for EXTERNAL ones.
  final sourceLabel = isExternal ? 'external' : 'vendor';
  final baseManifestFile = File(p.join(codeDir.path, 'manifest.json'));
  if (!baseManifestFile.existsSync()) {
    error(
      isExternal
          ? 'external source missing: '
              '${p.relative(baseManifestFile.path, from: repoRoot.path)} — '
              'run: git submodule update --init vendor/external/$id'
          : 'vendor source missing: ${p.relative(baseManifestFile.path)} — '
              'run: git submodule update --init',
    );
    return fail();
  }

  // ── base manifest ───────────────────────────────────────────────────────
  // Parsed LENIENTLY (raw JSON + id check only): the runtime examples
  // legitimately lack catalog fields (minRuntime/tags) that the overlay
  // supplies — only the MERGED manifest must satisfy the full schema.
  Map<String, dynamic> baseRaw;
  try {
    final decoded = jsonDecode(baseManifestFile.readAsStringSync());
    if (decoded is! Map) {
      error('$sourceLabel manifest.json must be a JSON object');
      return fail();
    }
    baseRaw = decoded.cast<String, dynamic>();
  } on FormatException catch (e) {
    error('$sourceLabel manifest.json is not valid JSON: ${e.message}');
    return fail();
  }
  if (baseRaw['id'] != id) {
    error(
      "$sourceLabel manifest id '${baseRaw['id']}' must equal the folder "
      "name '$id'",
    );
  }

  // ── merge (overlay meta wins over the allowed keys) ─────────────────────
  final mergedRaw = <String, dynamic>{
    ...baseRaw,
    for (final key in allowedOverlayKeys)
      if (overlay[key] != null) key: overlay[key],
  };
  final manifest = WidgetManifest.fromJson(mergedRaw);

  // ── shared semantic checks on the MERGED manifest ───────────────────────
  final idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,31}$');
  if (!idPattern.hasMatch(manifest.id)) {
    error("manifest id '${manifest.id}' must match [a-z0-9][a-z0-9-]{1,31}");
  }
  if (!isValidSemver(manifest.version)) {
    error("version '${manifest.version}' must be strict semver X.Y.Z");
  }
  _validateMinRuntime(manifest, error);
  _validateRuntimeFlags(manifest, error);
  _validatePlatforms(manifest, warn);

  final entry = File(p.join(codeDir.path, 'widget.js'));
  if (isExternal) {
    // An EXTERNAL widget's entry is widget.js OR the manifest-declared
    // live-tile entry (`widget.entry`).
    final declaredEntry = _declaredWidgetEntry(manifest);
    if (declaredEntry != null &&
        (declaredEntry.contains('..') || declaredEntry.startsWith('/'))) {
      error(
        "widget entry '$declaredEntry' must be a relative path inside "
        'the repo',
      );
    } else if (!entry.existsSync() &&
        (declaredEntry == null ||
            !File(p.join(codeDir.path, declaredEntry)).existsSync())) {
      error(
        'external source has no entry: missing widget.js'
        '${declaredEntry != null ? " and the manifest-declared widget entry '$declaredEntry'" : ''}',
      );
    } else if (entry.existsSync()) {
      final bytes = entry.readAsBytesSync();
      if (bytes.isEmpty) {
        error('external widget.js is empty');
      } else if (bytes.length > 1024 * 1024) {
        warn('external widget.js larger than 1 MiB');
      }
    }
  } else {
    if (!entry.existsSync()) {
      error('vendor widget.js entry missing');
    } else {
      final bytes = entry.readAsBytesSync();
      if (bytes.isEmpty) {
        error('vendor widget.js is empty');
      } else if (bytes.length > 1024 * 1024) {
        warn('vendor widget.js larger than 1 MiB');
      }
    }
  }
  _validateIcon(
    dir,
    manifest,
    error,
    warn,
    fallbackDir: isExternal ? codeDir : null,
  );
  if (manifest.description.isEmpty) warn('no description');

  // ── publishable source: submodule files (manifest REPLACED by the merge)
  //    + the local icon ───────────────────────────────────────────────────
  // `.git` is skipped: a submodule checkout carries it as a gitdir pointer
  // FILE (or, in hand-initialized checkouts, a directory).
  final codeFiles = codeDir
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (file) => !p
            .split(p.relative(file.path, from: codeDir.path))
            .contains('.git'),
      )
      .toList();
  _validateBudget(codeFiles, warn);

  List<({String path, List<int> bytes})>? sourceFiles;
  if (errors.isEmpty) {
    final iconFile = File('${dir.path}/${manifest.icon}');
    final hasLocalIcon = manifest.icon.isNotEmpty && iconFile.existsSync();
    sourceFiles = [
      for (final file in codeFiles)
        if (p.basename(file.path) != 'manifest.json' &&
            // A local icon OVERRIDES one shipped in the submodule.
            !(hasLocalIcon &&
                p
                        .relative(file.path, from: codeDir.path)
                        .replaceAll('\\', '/') ==
                    manifest.icon))
          (
            path: p
                .relative(file.path, from: codeDir.path)
                .replaceAll('\\', '/'),
            bytes: file.readAsBytesSync(),
          ),
      (path: 'manifest.json', bytes: utf8.encode(manifest.encode())),
      if (hasLocalIcon)
        (path: manifest.icon, bytes: iconFile.readAsBytesSync()),
    ];
  }
  return WidgetValidation._(
    dir,
    manifest,
    errors,
    warnings,
    sourceFiles,
    externalSource,
  );
}

final _sourceRepoPattern = RegExp(r'^[\w.-]+/[\w.-]+$');
final _sourceCommitPattern = RegExp(r'^[0-9a-f]{40}$');

/// Parses the REQUIRED `source` block of an EXTERNAL overlay. Returns null
/// (after reporting errors) when the block is structurally broken.
ExternalSource? _parseExternalSource(
  Object? raw,
  void Function(String) error,
) {
  if (raw is! Map) {
    error(
      "overlay 'source' must be an object: "
      '{"repo": "owner/name", "commit": "<40-hex sha>"}',
    );
    return null;
  }
  final repo = raw['repo'];
  final commit = raw['commit'];
  var ok = true;
  if (repo is! String || !_sourceRepoPattern.hasMatch(repo)) {
    error(
      "source.repo must be a GitHub 'owner/name' slug "
      '([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+), got ${repo == null ? 'missing' : "'$repo'"}',
    );
    ok = false;
  }
  if (commit is! String || !_sourceCommitPattern.hasMatch(commit)) {
    error(
      'source.commit must be a full 40-hex sha, '
      'got ${commit == null ? 'missing' : "'$commit'"}',
    );
    ok = false;
  }
  return ok
      ? ExternalSource(repo: repo as String, commit: commit as String)
      : null;
}

/// EXTERNAL-only checks the vendored path never needs: the per-widget
/// submodule at `vendor/external/<id>` must exist, be a git checkout pinned
/// at exactly the overlay's `source.commit` (drift = the overlay lies about
/// what ships), and be registered in the ROOT `.gitmodules` pointing at the
/// same repo. Returns false when any error was reported.
bool _validateExternalSubmodule(
  Directory codeDir,
  ExternalSource source,
  Directory repoRoot,
  void Function(String) error,
) {
  final id = p.basename(codeDir.path);
  final submodulePath = 'vendor/external/$id';
  final initHint = 'run: git submodule update --init $submodulePath';
  var ok = true;

  if (!codeDir.existsSync()) {
    error('external submodule $submodulePath is missing — $initHint');
    return false;
  }

  String? head;
  try {
    final result = Process.runSync(
      'git',
      ['-C', codeDir.path, 'rev-parse', 'HEAD'],
    );
    if (result.exitCode == 0) {
      final out = (result.stdout as String).trim();
      if (out.isNotEmpty) head = out;
    }
  } on ProcessException {
    head = null;
  }
  if (head == null) {
    error('$submodulePath is not a git submodule checkout — $initHint');
    ok = false;
  } else if (head != source.commit) {
    error(
      'source.commit ${source.commit} does not match the $submodulePath '
      'submodule HEAD $head (drift) — re-pin the submodule to the pushed '
      'commit and update the overlay',
    );
    ok = false;
  }

  final url =
      _gitmodulesUrl(File(p.join(repoRoot.path, '.gitmodules')), submodulePath);
  if (url == null) {
    error(
      '.gitmodules has no entry for path $submodulePath — register it: '
      'git submodule add https://github.com/${source.repo}.git '
      '$submodulePath',
    );
    ok = false;
  } else if (!_gitmodulesUrlMatches(url, source.repo)) {
    error(
      ".gitmodules url '$url' for $submodulePath does not point at "
      "source.repo '${source.repo}'",
    );
    ok = false;
  }
  return ok;
}

/// Reads a `.gitmodules` file and returns the registered url of the
/// submodule whose `path` equals [submodulePath], or null when the file or
/// the entry is missing. (Minimal INI scan — no quoting games: git writes
/// these sections flat.)
String? _gitmodulesUrl(File gitmodules, String submodulePath) {
  if (!gitmodules.existsSync()) return null;
  String? result;
  String? currentPath;
  String? currentUrl;
  void flush() {
    if (currentPath == submodulePath && currentUrl != null) {
      result ??= currentUrl;
    }
  }

  for (final line in gitmodules.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.startsWith('[')) {
      flush();
      currentPath = null;
      currentUrl = null;
      continue;
    }
    final eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    final key = trimmed.substring(0, eq).trim();
    final value = trimmed.substring(eq + 1).trim();
    if (key == 'path') currentPath = value;
    if (key == 'url') currentUrl = value;
  }
  flush();
  return result;
}

/// Whether a `.gitmodules` url points at the GitHub repo [repo]
/// (`owner/name`): accepts the https form with or without `.git` and the
/// ssh form (`git@github.com:owner/name.git`).
bool _gitmodulesUrlMatches(String url, String repo) {
  final normalized =
      url.endsWith('.git') ? url.substring(0, url.length - 4) : url;
  return normalized.endsWith('/$repo') || normalized.endsWith(':$repo');
}

/// The manifest-declared live-tile entry (`widget.entry`), or null.
String? _declaredWidgetEntry(WidgetManifest manifest) {
  final widget = manifest.raw['widget'];
  if (widget is! Map) return null;
  final entry = widget['entry'];
  return entry is String && entry.trim().isNotEmpty ? entry.trim() : null;
}

void _validateMinRuntime(
  WidgetManifest manifest,
  void Function(String) error,
) {
  if (manifest.minRuntime.isEmpty) {
    error("missing required 'minRuntime' (js_widget_runtime floor)");
  } else if (!isValidSemver(manifest.minRuntime)) {
    error("minRuntime '${manifest.minRuntime}' must be strict semver X.Y.Z");
  }
}

void _validateRuntimeFlags(
  WidgetManifest manifest,
  void Function(String) error,
) {
  final rawNetwork = manifest.raw['network'];
  if (rawNetwork != null && rawNetwork is! bool) {
    error("'network' must be a boolean");
  }
  final rawCommands = manifest.raw['allowedCommands'];
  if (rawCommands != null && rawCommands is! List) {
    error("'allowedCommands' must be a list");
  }
}

void _validatePlatforms(
  WidgetManifest manifest,
  void Function(String) warn,
) {
  final rawPlatforms = manifest.raw['platforms'];
  if (rawPlatforms == null) return;
  if (rawPlatforms is! List) {
    warn("'platforms' must be a list of non-empty strings");
    return;
  }
  var shapeWarned = false;
  for (final platform in rawPlatforms) {
    if (platform is! String || platform.trim().isEmpty) {
      if (!shapeWarned) {
        warn("'platforms' must be a list of non-empty strings");
        shapeWarned = true;
      }
      continue;
    }
    if (!knownPlatforms.contains(platform.trim().toLowerCase())) {
      warn(
        "unknown platform '$platform' "
        '(known: ${knownPlatforms.join(', ')})',
      );
    }
  }
}

void _validateIcon(
  Directory dir,
  WidgetManifest manifest,
  void Function(String) error,
  void Function(String) warn, {
  /// EXTERNAL widgets may ship the icon in the user repo itself — the
  /// local overlay dir still wins when both exist.
  Directory? fallbackDir,
}) {
  final icon = manifest.icon;
  if (icon.isNotEmpty) {
    if (icon.contains('..') || icon.startsWith('/')) {
      error("icon '$icon' must be a relative path inside the widget dir");
    } else if (!File('${dir.path}/$icon').existsSync() &&
        !(fallbackDir != null &&
            File('${fallbackDir.path}/$icon').existsSync())) {
      error("icon '$icon' not found");
    }
  } else {
    warn('no icon declared — gallery will show a placeholder');
  }
}

void _validateBudget(List<File> files, void Function(String) warn) {
  var totalBytes = 0;
  for (final entity in files) {
    totalBytes += entity.lengthSync();
  }
  if (totalBytes > sizeWarnBytes) {
    warn(
      'widget weighs ${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MiB '
      '(>$sizeWarnBytes limit) — consider hosting heavy assets externally',
    );
  }
  if (files.length > fileCountWarn) {
    warn('${files.length} files exceed the soft cap of $fileCountWarn');
  }
}

/// Validates every direct child directory of the widgets root.
/// Returns one [WidgetValidation] per widget folder. [vendorRoot] points
/// at the `flutter_js_widget_runtime` submodule checkout (default:
/// `../vendor/js_widget_runtime` next to the widgets root); [repoRoot] is
/// the catalog repo root holding `.gitmodules` + `vendor/external/<id>/`
/// for EXTERNAL widgets (default: the widgets root's parent).
List<WidgetValidation> validateWidgetsRoot(
  Directory widgetsRoot, {
  Directory? vendorRoot,
  Directory? repoRoot,
}) {
  final effectiveRepoRoot = repoRoot ?? Directory(p.dirname(widgetsRoot.path));
  final effectiveVendorRoot = vendorRoot ??
      Directory(
        p.join(
          effectiveRepoRoot.path,
          'vendor',
          'js_widget_runtime',
        ),
      );
  final results = <WidgetValidation>[];
  for (final entity in widgetsRoot.listSync().whereType<Directory>()) {
    results.add(
      validateWidgetDirectory(
        entity,
        vendorRoot: effectiveVendorRoot,
        repoRoot: effectiveRepoRoot,
      ),
    );
  }
  return results
    ..sort(
      (WidgetValidation a, WidgetValidation b) =>
          a.directory.path.compareTo(b.directory.path),
    );
}
