import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'issues.dart';
import 'manifest.dart';
import 'validator.dart';

/// One built widget: validation result + the produced artifacts.
final class BuiltWidget {
  BuiltWidget({
    required this.validation,
    required this.manifest,
    required this.zipFile,
    required this.sha256,
    required this.sizeBytes,
  });

  final WidgetValidation validation;
  final WidgetManifest manifest;

  /// The `<id>-<version>.zip` file name (flat release-asset name).
  final String zipFile;

  /// Hex sha256 over the exact zip bytes.
  final String sha256;
  final int sizeBytes;
}

/// Builds a catalog from a widgets root into an output directory.
/// The fixed DOS-friendly mtime stamped on every zip entry (1980-01-01,
/// the zip epoch): rebuilds over unchanged sources are byte-identical,
/// keeping published sha256 values stable.
const int canonicalZipTimestamp = 315532800;

final class CatalogBuilder {
  CatalogBuilder({
    required this.widgetsRoot,
    this.vendorRoot,
    this.repoRoot,
    this.vendorRef = 'main',
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final Directory widgetsRoot;

  /// The `flutter_js_widget_runtime` submodule checkout (vendored widget
  /// sources); the validator defaults it to `../vendor/js_widget_runtime`
  /// next to [widgetsRoot].
  final Directory? vendorRoot;

  /// The catalog repo root holding `.gitmodules` + `vendor/external/<id>/`
  /// (EXTERNAL widget sources); defaults to the parent of [widgetsRoot].
  final Directory? repoRoot;

  /// The git ref (tag/sha) the vendor submodule is pinned at — used for
  /// the `preview` URLs of vendored widgets so the web preview runner
  /// fetches EXACTLY the code that went into the zip.
  final String vendorRef;
  final DateTime Function() _now;

  /// Validates everything first; only when EVERY widget passes, writes
  /// `<id>-<version>.zip` per widget and `catalog.json`. Throws
  /// [CatalogBuildException] otherwise — publishing is all-or-nothing so
  /// the rolling release never ends up half-current, and a rejected build
  /// leaves no artifacts behind.
  CatalogResult build({required Directory outDir}) {
    final results = validateWidgetsRoot(
      widgetsRoot,
      vendorRoot: vendorRoot,
      repoRoot: repoRoot,
    );
    final fatal = [
      for (final result in results)
        for (final error in result.errors) error,
    ];
    if (fatal.isNotEmpty) {
      throw CatalogBuildException(fatal);
    }
    outDir.createSync(recursive: true);

    final entries = <Map<String, dynamic>>[];
    final warnings = <String>[];
    for (final result in results) {
      warnings.addAll(result.warnings.map((w) => w.message));
      final manifest = result.manifest!;
      final id = manifest.id;
      final version = manifest.version;
      final zipPath = p.join(outDir.path, '$id-$version.zip');
      final bytes = _writeZip(result.sourceFiles!, rootFolderName: id);
      File(zipPath).writeAsBytesSync(bytes);

      entries.add({
        'id': id,
        'name': manifest.name,
        'version': version,
        if (manifest.description.isNotEmpty)
          'description': manifest.description,
        if (manifest.author.isNotEmpty) 'author': manifest.author,
        if (manifest.tags.isNotEmpty) 'tags': manifest.tags.toList(),
        ..._platformsEntry(manifest),
        'permissions': {
          'network': manifest.network,
          'allowedCommands': manifest.allowedCommands.toList(),
        },
        'minRuntime': manifest.minRuntime,
        if (result.externalSource != null)
          'source': {
            'repo': result.externalSource!.repo,
            'commit': result.externalSource!.commit,
          },
        if (manifest.icon.isNotEmpty) 'icon': manifest.icon,
        'zip': {
          'file': '$id-$version.zip',
          'sha256': sha256.convert(bytes).toString(),
          'sizeBytes': bytes.length,
        },
        'preview': _previewEntry(result),
      });
    }
    entries.sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          (a['id'] as String).compareTo(b['id'] as String),
    );

    final catalog = {
      'schemaVersion': 1,
      'generatedAt': _now().toIso8601String(),
      'sourceRepo': 'https://github.com/IstiN/fa_widgets',
      'widgets': entries,
    };
    final catalogPath = p.join(outDir.path, 'catalog.json');
    final encoder = JsonEncoder.withIndent('  ');
    File(catalogPath).writeAsStringSync('${encoder.convert(catalog)}\n');

    return CatalogResult(
      catalogFile: File(catalogPath),
      zipFiles: [
        for (final entry in entries)
          File(p.join(outDir.path, entry['zip']['file'] as String)),
      ],
      warnings: warnings,
    );
  }

  /// Where the web preview runner (jsr's GitHub Pages) fetches this
  /// widget's manifest.json + widget.js. VENDORED widgets live in the
  /// runtime repo (the fa_widgets repo only holds the overlay — raw
  /// github does not follow submodules), pinned at [vendorRef] so the
  /// preview shows exactly what shipped in the zip; EXTERNAL widgets live
  /// in the user's public repo, pinned at the overlay's `source.commit`;
  /// LOCAL widgets live in this repo on main.
  Map<String, String> _previewEntry(WidgetValidation result) {
    final id = result.manifest!.id;
    final source = result.externalSource;
    if (source != null) {
      final base = 'https://raw.githubusercontent.com/${source.repo}/'
          '${source.commit}';
      return {'manifest': '$base/manifest.json', 'js': '$base/widget.js'};
    }
    final vendored =
        File(p.join(result.directory.path, 'overlay.json')).existsSync();
    final base = vendored
        ? 'https://raw.githubusercontent.com/IstiN/flutter_js_widget_runtime/'
            '$vendorRef/example/widgets/$id'
        : 'https://raw.githubusercontent.com/IstiN/fa_widgets/main/'
            'widgets/$id';
    return {'manifest': '$base/manifest.json', 'js': '$base/widget.js'};
  }

  /// Zips [entries] (`path-in-widget` + bytes) under a single root folder
  /// [rootFolderName], entries sorted by path. Every entry gets the
  /// CANONICAL mtime so the bytes — and therefore the published sha256 —
  /// are deterministic across rebuilds: a re-run of the publish pipeline
  /// over unchanged sources must produce the exact same asset, or the app
  /// (which may hold a cached catalog) fails installs with a hash
  /// mismatch. The entry list comes from validation — local widget dirs
  /// verbatim, or vendor code + synthesized merged manifest + local icon
  /// for vendored widgets.
  List<int> _writeZip(
    List<({String path, List<int> bytes})> entries, {
    required String rootFolderName,
  }) {
    final encoder = ZipEncoder();
    final archive = Archive();
    final sorted = entries.toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in sorted) {
      archive.addFile(
        ArchiveFile(
            '$rootFolderName/${entry.path}', entry.bytes.length, entry.bytes)
          ..compress = true
          ..lastModTime = canonicalZipTimestamp,
      );
    }
    return encoder.encode(archive)!;
  }
}

/// The optional `platforms` catalog field: the manifest's declared list,
/// verbatim, but only when it holds at least one non-empty string
/// (defensive — malformed entries are dropped, not propagated).
Map<String, dynamic> _platformsEntry(WidgetManifest manifest) {
  final raw = manifest.raw['platforms'];
  if (raw is! List) return const {};
  final platforms = [
    for (final platform in raw)
      if (platform is String && platform.trim().isNotEmpty) platform.trim(),
  ];
  if (platforms.isEmpty) return const {};
  return {'platforms': platforms};
}

/// The outcome of a successful build.
final class CatalogResult {
  CatalogResult({
    required this.catalogFile,
    required this.zipFiles,
    required this.warnings,
  });

  final File catalogFile;
  final List<File> zipFiles;
  final List<String> warnings;
}

/// Thrown when any widget fails validation during a build.
final class CatalogBuildException implements Exception {
  CatalogBuildException(this.errors);

  final List<ValidationError> errors;

  @override
  String toString() =>
      'catalog build failed:\n${errors.map((e) => '  - $e').join('\n')}';
}

/// One widget whose version needs a fresh immutable release tag.
final class TagChange {
  const TagChange({required this.id, required this.version});

  /// Widget id (folder/manifest identity).
  final String id;

  /// The NEW version being published.
  final String version;

  /// `<id>-v<version>` — the git/release tag for this artifact.
  String get tagName => '$id-v$version';

  @override
  String toString() => '$id $version';
}

/// Compares the freshly built catalog against the currently published one
/// and lists widgets that are new or version-bumped (the publish workflow
/// cuts an immutable `<id>-v<version>` tag per line).
///
/// [previousCatalog] may be missing, empty or malformed (first publish /
/// GH hiccup) — everything in [currentCatalog] is then treated as new.
/// Within schemaVersion 1 unknown entry shapes are skipped silently.
List<TagChange> diffTagChanges(
  Map<String, dynamic>? previousCatalog,
  Map<String, dynamic> currentCatalog,
) {
  String? idOf(Map<String, dynamic> entry) =>
      entry['id'] is String ? entry['id'] as String : null;
  String? versionOf(Map<String, dynamic> entry) =>
      entry['version'] is String ? entry['version'] as String : null;

  final previous = <String, String>{
    if (previousCatalog != null)
      for (final raw in previousCatalog['widgets'] as List? ?? const [])
        if (raw is Map && idOf(raw.cast<String, dynamic>()) != null)
          idOf(raw.cast<String, dynamic>())!:
              versionOf(raw.cast<String, dynamic>()) ?? '',
  };

  final changes = <TagChange>[];
  for (final raw in currentCatalog['widgets'] as List? ?? const []) {
    if (raw is! Map) continue;
    final entry = raw.cast<String, dynamic>();
    final id = idOf(entry);
    final version = versionOf(entry);
    if (id == null || version == null || version.isEmpty) continue;
    if (previous[id] != version) {
      changes.add(TagChange(id: id, version: version));
    }
  }
  return changes
    ..sort(
      (TagChange a, TagChange b) => a.id.compareTo(b.id),
    );
}
