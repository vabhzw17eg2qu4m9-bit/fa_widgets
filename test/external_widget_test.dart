import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fa_widgets_tool/src/catalog_builder.dart';
import 'package:fa_widgets_tool/src/validator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// EXTERNAL (user-repo-sourced) widgets: `widgets/<id>/overlay.json` with a
/// `source: {repo, commit}` block + the code in a per-widget git submodule
/// at `vendor/external/<id>/` (flutter_agent_harness #35).
///
/// The fixtures build REAL git repos in temp dirs — the validator shells
/// out to `git rev-parse HEAD` for the pin/drift check, so a bare directory
/// is not enough.

/// The pieces of an external-widget fixture.
typedef ExternalFixture = ({
  Directory repoRoot,
  Directory widgetsRoot,
  Directory submoduleDir,
  String head,
});

/// Runs `git` inside [dir], failing the test on non-zero exit.
Future<void> _git(Directory dir, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: dir.path);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

/// Initializes [dir] as a git repo, commits everything, returns the HEAD sha.
Future<String> _gitInitAndCommit(Directory dir) async {
  await _git(dir, ['init', '-q']);
  await _git(dir, ['add', '-A']);
  await _git(dir, [
    '-c',
    'user.email=test@example.com',
    '-c',
    'user.name=Test',
    'commit',
    '-q',
    '-m',
    'widget',
  ]);
  final rev = await Process.run(
    'git',
    ['rev-parse', 'HEAD'],
    workingDirectory: dir.path,
  );
  return (rev.stdout as String).trim();
}

/// Builds an external-widget fixture: a fake catalog repo root holding
/// `widgets/<id>/overlay.json` + local icon, the user repo at
/// `vendor/external/<id>/` (a REAL git repo unless [initGit] is false) and
/// a `.gitmodules` registration (unless [withGitmodules] is false).
Future<ExternalFixture> writeExternalWidget(
  String id, {
  Map<String, Object?>? overlay,
  Map<String, Object?>? manifest,
  String? gitmodulesUrl,
  bool createSubmodule = true,
  bool initGit = true,
  bool withGitmodules = true,
  bool withEntry = true,
}) async {
  final repoRoot = await Directory.systemTemp.createTemp('faw_ext_repo');
  final widgetsRoot = Directory(p.join(repoRoot.path, 'widgets'))
    ..createSync();
  final widgetDir = Directory(p.join(widgetsRoot.path, id))..createSync();
  File(p.join(widgetDir.path, 'icon.svg')).writeAsStringSync('<svg>ext</svg>');

  var head = '0' * 40;
  final submoduleDir = Directory(
    p.join(repoRoot.path, 'vendor', 'external', id),
  );
  if (createSubmodule) {
    submoduleDir.createSync(recursive: true);
    File(p.join(submoduleDir.path, 'manifest.json')).writeAsStringSync(
      jsonEncode({
        'id': id,
        'name': 'External $id',
        'description': 'From my own repo',
        'version': '3.1.4',
        'network': false,
        'allowedCommands': <String>[],
        ...?manifest,
      }),
    );
    if (withEntry) {
      File(p.join(submoduleDir.path, 'widget.js')).writeAsStringSync(
        '(function(){ jsr.render({type:"text",data:"external"}); })();',
      );
    }
    if (initGit) {
      head = await _gitInitAndCommit(submoduleDir);
    }
  }

  if (withGitmodules) {
    File(p.join(repoRoot.path, '.gitmodules')).writeAsStringSync(
      '[submodule "vendor/external/$id"]\n'
      '\tpath = vendor/external/$id\n'
      '\turl = ${gitmodulesUrl ?? 'https://github.com/octocat/fa-widget-$id.git'}\n',
    );
  }

  File(p.join(widgetDir.path, 'overlay.json')).writeAsStringSync(
    jsonEncode({
      'icon': 'icon.svg',
      'tags': ['demo'],
      'author': 'Octocat',
      'minRuntime': '0.4.89',
      'source': {'repo': 'octocat/fa-widget-$id', 'commit': head},
      ...?overlay,
    }),
  );
  return (
    repoRoot: repoRoot,
    widgetsRoot: widgetsRoot,
    submoduleDir: submoduleDir,
    head: head,
  );
}

void main() {
  group('external (user-repo submodule) widgets', () {
    test(
      'a valid external widget validates; version comes from its own repo',
      () async {
        final fixture = await writeExternalWidget('ext-demo');
        try {
          final result =
              validateWidgetsRoot(fixture.widgetsRoot).single;
          expect(result.errors, isEmpty, reason: result.errors.join('\n'));
          final manifest = result.manifest!;
          // Version/id/name from the SUBMODULE manifest, meta from overlay.
          expect(manifest.id, 'ext-demo');
          expect(manifest.version, '3.1.4');
          expect(manifest.name, 'External ext-demo');
          expect(manifest.tags, ['demo']);
          expect(manifest.author, 'Octocat');
          expect(manifest.minRuntime, '0.4.89');
          expect(
            result.externalSource!.repo,
            'octocat/fa-widget-ext-demo',
          );
          expect(result.externalSource!.commit, fixture.head);
        } finally {
          await fixture.repoRoot.delete(recursive: true);
        }
      },
    );

    test('the ssh-form .gitmodules url is accepted', () async {
      final fixture = await writeExternalWidget(
        'ext-demo',
        gitmodulesUrl: 'git@github.com:octocat/fa-widget-ext-demo.git',
      );
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.errors, isEmpty, reason: result.errors.join('\n'));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test('drift (overlay commit != submodule HEAD) fails', () async {
      final fixture = await writeExternalWidget(
        'ext-demo',
        overlay: {
          'source': {
            'repo': 'octocat/fa-widget-ext-demo',
            'commit': '1' * 40,
          },
        },
      );
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.isValid, isFalse);
        expect(result.errors.join('\n'), contains('does not match'));
        expect(result.errors.join('\n'), contains(fixture.head));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test(
      'a missing submodule errors with the update --init hint',
      () async {
        final fixture = await writeExternalWidget(
          'ext-demo',
          createSubmodule: false,
        );
        try {
          final result = validateWidgetsRoot(fixture.widgetsRoot).single;
          expect(result.isValid, isFalse);
          expect(
            result.errors.join('\n'),
            contains('git submodule update --init vendor/external/ext-demo'),
          );
        } finally {
          await fixture.repoRoot.delete(recursive: true);
        }
      },
    );

    test(
      'a submodule directory that is not a git checkout errors with the hint',
      () async {
        final fixture = await writeExternalWidget('ext-demo', initGit: false);
        try {
          final result = validateWidgetsRoot(fixture.widgetsRoot).single;
          expect(result.isValid, isFalse);
          expect(
            result.errors.join('\n'),
            contains('not a git submodule checkout'),
          );
          expect(
            result.errors.join('\n'),
            contains('git submodule update --init vendor/external/ext-demo'),
          );
        } finally {
          await fixture.repoRoot.delete(recursive: true);
        }
      },
    );

    test('a malformed source.repo fails', () async {
      final fixture = await writeExternalWidget(
        'ext-demo',
        overlay: {
          'source': {'repo': 'no-slash-here', 'commit': '0' * 40},
        },
      );
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.isValid, isFalse);
        expect(result.errors.join('\n'), contains('source.repo'));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test('a malformed source.commit fails', () async {
      final fixture = await writeExternalWidget(
        'ext-demo',
        overlay: {
          'source': {'repo': 'octocat/fa-widget-ext-demo', 'commit': 'abc123'},
        },
      );
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.isValid, isFalse);
        expect(result.errors.join('\n'), contains('source.commit'));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test('an overlay with forbidden keys still fails (source or not)',
        () async {
      final fixture = await writeExternalWidget(
        'ext-demo',
        overlay: {'version': '9.9.9'},
      );
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.isValid, isFalse);
        expect(result.errors.join('\n'), contains('not allowed'));
        expect(result.errors.join('\n'), contains('version'));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test('a missing .gitmodules registration fails', () async {
      final fixture = await writeExternalWidget(
        'ext-demo',
        withGitmodules: false,
      );
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.isValid, isFalse);
        expect(result.errors.join('\n'), contains('.gitmodules'));
        expect(result.errors.join('\n'), contains('vendor/external/ext-demo'));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test('a .gitmodules url pointing at another repo fails', () async {
      final fixture = await writeExternalWidget(
        'ext-demo',
        gitmodulesUrl: 'https://github.com/someone-else/other-repo.git',
      );
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.isValid, isFalse);
        expect(result.errors.join('\n'), contains('does not point at'));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test(
      'the manifest-declared widget entry substitutes a missing widget.js',
      () async {
        final fixture = await writeExternalWidget(
          'ext-demo',
          withEntry: false,
          manifest: {
            'widget': {'entry': 'tile.js', 'size': '2x2'},
          },
        );
        try {
          File(p.join(fixture.submoduleDir.path, 'tile.js'))
              .writeAsStringSync(
            '(function(){ jsr.render({type:"text",data:"tile"}); })();',
          );
          // Re-commit so the pin matches the fixture overlay.
          await _git(fixture.submoduleDir, ['add', '-A']);
          await _git(fixture.submoduleDir, [
            '-c',
            'user.email=test@example.com',
            '-c',
            'user.name=Test',
            'commit',
            '-q',
            '-m',
            'tile entry',
          ]);
          final rev = await Process.run(
            'git',
            ['rev-parse', 'HEAD'],
            workingDirectory: fixture.submoduleDir.path,
          );
          final head = (rev.stdout as String).trim();
          File(
            p.join(fixture.widgetsRoot.path, 'ext-demo', 'overlay.json'),
          ).writeAsStringSync(
            jsonEncode({
              'icon': 'icon.svg',
              'minRuntime': '0.4.89',
              'source': {
                'repo': 'octocat/fa-widget-ext-demo',
                'commit': head,
              },
            }),
          );

          final result = validateWidgetsRoot(fixture.widgetsRoot).single;
          expect(result.errors, isEmpty, reason: result.errors.join('\n'));
        } finally {
          await fixture.repoRoot.delete(recursive: true);
        }
      },
    );

    test('no widget.js and no declared entry fails', () async {
      final fixture = await writeExternalWidget('ext-demo', withEntry: false);
      try {
        final result = validateWidgetsRoot(fixture.widgetsRoot).single;
        expect(result.isValid, isFalse);
        expect(result.errors.join('\n'), contains('no entry'));
      } finally {
        await fixture.repoRoot.delete(recursive: true);
      }
    });

    test(
      'build packs the zip from the submodule and carries source through',
      () async {
        final fixture = await writeExternalWidget('ext-demo');
        final out = await Directory.systemTemp.createTemp('faw_ext_out');
        try {
          final result = CatalogBuilder(
            widgetsRoot: fixture.widgetsRoot,
          ).build(outDir: out);

          expect(result.zipFiles, hasLength(1));
          expect(
            p.basename(result.zipFiles.single.path),
            'ext-demo-3.1.4.zip',
          );
          final archive =
              ZipDecoder().decodeBytes(result.zipFiles.single.readAsBytesSync());
          final names = archive.files.map((f) => f.name).toList();
          expect(names, contains('ext-demo/widget.js'));
          expect(names, contains('ext-demo/manifest.json'));
          expect(names, contains('ext-demo/icon.svg'));
          // Git internals never leak into the zip.
          expect(names.any((n) => n.contains('.git')), isFalse);

          String entry(String name) => utf8.decode(
                archive.files.firstWhere((f) => f.name == name).content
                    as List<int>,
              );
          expect(entry('ext-demo/widget.js'), contains('external'));
          final manifest = jsonDecode(entry('ext-demo/manifest.json'))
              as Map<String, dynamic>;
          expect(manifest['version'], '3.1.4');
          expect(manifest['minRuntime'], '0.4.89');
          expect(entry('ext-demo/icon.svg'), '<svg>ext</svg>');

          // The catalog entry carries source through and preview URLs point
          // at the user repo pinned at the exact commit.
          final catalog = jsonDecode(result.catalogFile.readAsStringSync())
              as Map<String, dynamic>;
          final widgetEntry =
              (catalog['widgets'] as List).single as Map<String, dynamic>;
          expect(widgetEntry['version'], '3.1.4');
          expect(widgetEntry['source'], {
            'repo': 'octocat/fa-widget-ext-demo',
            'commit': fixture.head,
          });
          final preview = widgetEntry['preview'] as Map<String, dynamic>;
          expect(
            preview['manifest'],
            'https://raw.githubusercontent.com/octocat/fa-widget-ext-demo/'
            '${fixture.head}/manifest.json',
          );
          expect(
            preview['js'],
            'https://raw.githubusercontent.com/octocat/fa-widget-ext-demo/'
            '${fixture.head}/widget.js',
          );
        } finally {
          await fixture.repoRoot.delete(recursive: true);
          await out.delete(recursive: true);
        }
      },
    );
  });
}
