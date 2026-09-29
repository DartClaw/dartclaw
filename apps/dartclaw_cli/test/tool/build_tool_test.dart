@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _repoRoot() {
  final start =
      Platform.environment['DARTCLAW_REPO_ROOT'] ??
      Platform.environment['GITHUB_WORKSPACE'] ??
      Platform.environment['PWD'] ??
      Directory.current.absolute.path;
  var current = start;
  while (true) {
    if (File(p.join(current, 'dev', 'tools', 'build.sh')).existsSync() &&
        Directory(p.join(current, 'apps')).existsSync()) {
      return current;
    }
    final parent = p.dirname(current);
    if (parent == current) throw StateError('Unable to locate repository root from $start');
    current = parent;
  }
}

String _hostOsName() => switch ((Process.runSync('uname', ['-s']).stdout as String).trim()) {
  'Darwin' => 'macos',
  'Linux' => 'linux',
  final value => value.toLowerCase(),
};

String _hostArchName() => switch ((Process.runSync('uname', ['-m']).stdout as String).trim()) {
  'x86_64' || 'amd64' => 'x64',
  'aarch64' || 'arm64' => 'arm64',
  final value => value.toLowerCase(),
};

String _hashFile(String path) {
  for (final command in [
    ('sha256sum', [path]),
    ('shasum', ['-a', '256', path]),
  ]) {
    try {
      final result = Process.runSync(command.$1, command.$2);
      if (result.exitCode == 0) return (result.stdout as String).trim().split(RegExp(r'\s+')).first;
    } on ProcessException {
      continue;
    }
  }
  throw StateError('No SHA-256 checksum tool found.');
}

List<String> _tarEntries(String archivePath) {
  final result = Process.runSync('tar', ['-tzf', archivePath]);
  if (result.exitCode != 0) throw StateError('tar failed: ${result.stderr}');
  return (result.stdout as String).trim().split('\n').where((line) => line.isNotEmpty).toList();
}

void main() {
  final repoRoot = _repoRoot();
  final buildScript = p.join(repoRoot, 'dev', 'tools', 'build.sh');
  final buildDir = Directory(p.join(repoRoot, 'build'));
  final version = dartclawVersion;

  test('native archive failures preserve existing build output and precede asset generation', () {
    final fixtureParent = Directory(p.join(repoRoot, '.agent_temp'))..createSync(recursive: true);
    final fixture = fixtureParent.createTempSync('native-build-prerequisite-');
    addTearDown(() => fixture.deleteSync(recursive: true));
    final fixtureBuildDir = Directory(p.join(fixture.path, 'build'))..createSync(recursive: true);
    final sentinel = File(p.join(fixtureBuildDir.path, 'previous-build.txt'))..writeAsStringSync('preserve me');
    final fixtureBuildScript = File(p.join(fixture.path, 'dev', 'tools', 'build.sh'));
    fixtureBuildScript.parent.createSync(recursive: true);
    File(buildScript).copySync(fixtureBuildScript.path);
    File(p.join(repoRoot, 'dev', 'tools', 'sync_version.dart'))
        .copySync(p.join(fixture.path, 'dev', 'tools', 'sync_version.dart'));
    final fixtureRuntime = Directory(p.join(fixture.path, 'packages', 'dartclaw_runtime'))..createSync(recursive: true);
    File(p.join(fixtureRuntime.path, 'pubspec.yaml')).writeAsStringSync('name: dartclaw_runtime\nversion: $version\n');
    final fixtureVersion = File(p.join(fixtureRuntime.path, 'lib', 'src', 'version.dart'));
    fixtureVersion.parent.createSync(recursive: true);
    fixtureVersion.writeAsStringSync("const dartclawVersion = '$version';\n");

    final fixtureBin = Directory(p.join(fixture.path, 'bin'))..createSync();
    final dartWrapper = File(p.join(fixtureBin.path, 'dart'))
      ..writeAsStringSync('''#!/bin/sh
if [ "\$1" = "run" ] && [ "\$2" = "apps/dartclaw_cli/tool/native_artifact_preparation.dart" ]; then
  shift 2
  exec "\$DARTCLAW_TEST_REAL_DART" "--packages=\$DARTCLAW_TEST_PACKAGE_CONFIG" "\$DARTCLAW_TEST_NATIVE_PREPARER" "\$@"
fi
exec "\$DARTCLAW_TEST_REAL_DART" "\$@"
''');
    Process.runSync('chmod', ['755', dartWrapper.path]);
    final target = '${_hostOsName()}-${_hostArchName()}';
    final release = 'v999.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final bundle = target == 'macos-x64' ? 'macos-x86_64' : target;
    final archive = 'llamadart-native-$bundle-$release.tar.gz';
    final expectedBytes = utf8.encode('expected archive');
    final manifest = File(p.join(fixture.path, 'manifest.json'))
      ..writeAsStringSync(
        jsonEncode({
          'release': release,
          'repository': 'https://example.test/native',
          'model': {
            'basename': 'tiny-model.gguf',
            'url': 'https://example.test/tiny-model.gguf',
            'size': expectedBytes.length,
            'sha256': sha256.convert(expectedBytes).toString(),
          },
          'artifacts': {
            target: {
              'bundle': bundle,
              'archive': archive,
              'url': 'https://example.test/$archive',
              'size': expectedBytes.length,
              'sha256': sha256.convert(expectedBytes).toString(),
            },
          },
        }),
      );

    final defaultCache = p.join(fixture.path, '.agent_temp', 'native-cache');
    final cases = <({String name, String cache, String expectedFailure})>[
      (name: 'missing default archive', cache: '', expectedFailure: 'Missing native archive $archive'),
      (
        name: 'invalid explicit archive',
        cache: (Directory(p.join(fixture.path, 'invalid-cache'))..createSync()).path,
        expectedFailure: 'Cached native archive $archive has the wrong size',
      ),
    ];
    File(p.join(cases.last.cache, archive)).writeAsStringSync('invalid');

    for (final testCase in cases) {
      final result = Process.runSync(
        'bash',
        [fixtureBuildScript.path],
        workingDirectory: fixture.path,
        environment: {
          'DARTCLAW_BUILD_SKIP_COMPILE': '1',
          'DARTCLAW_NATIVE_ALLOW_DOWNLOAD': '',
          'DARTCLAW_NATIVE_ARCHIVE_CACHE': testCase.cache,
          'DARTCLAW_NATIVE_MANIFEST': manifest.path,
          'DARTCLAW_RELEASE_TARGET': target,
          'DARTCLAW_TEST_NATIVE_PREPARER': p.join(
            repoRoot,
            'apps',
            'dartclaw_cli',
            'tool',
            'native_artifact_preparation.dart',
          ),
          'DARTCLAW_TEST_PACKAGE_CONFIG': p.join(repoRoot, '.dart_tool', 'package_config.json'),
          'DARTCLAW_TEST_REAL_DART': Platform.resolvedExecutable,
          'PATH': '${fixtureBin.path}:${Platform.environment['PATH'] ?? ''}',
        },
      );
      expect(result.exitCode, isNot(0), reason: testCase.name);
      expect(result.stderr, contains(testCase.expectedFailure), reason: testCase.name);
      if (testCase.cache.isEmpty) {
        expect(result.stderr, contains(defaultCache), reason: 'An empty override must select the repo-local default.');
      }
      expect(result.stdout, isNot(contains('==> Cross-compiling container bridge')), reason: testCase.name);
      expect(result.stdout, isNot(contains('==> Generating embedded assets')), reason: testCase.name);
      expect(sentinel.readAsStringSync(), 'preserve me', reason: testCase.name);
    }
  });

  test(
    'workflow-only: produces both archives with the excluded libraries absent',
    () async {
      addTearDown(() {
        if (buildDir.existsSync()) buildDir.deleteSync(recursive: true);
      });
      final result = await Process.run('bash', [buildScript], workingDirectory: repoRoot);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      final full = File(p.join(buildDir.path, 'bin', 'dartclaw')).readAsBytesSync();
      final lean = File(p.join(buildDir.path, 'bin', 'dartclaw-workflow')).readAsBytesSync();
      final fullText = String.fromCharCodes(full);
      final leanText = String.fromCharCodes(lean);
      const excludedLibraries = [
        'package:shelf/',
        'package:shelf_router/',
        'package:shelf_static/',
        'package:dartclaw_client/',
        'package:dartclaw_runtime/src/server.dart',
        'package:dartclaw_runtime/src/api/',
        'package:dartclaw_runtime/src/web/',
        'package:dartclaw_runtime/src/auth/auth_middleware.dart',
        'package:dartclaw_runtime/src/runtime/channel_wiring.dart',
        'package:dartclaw_whatsapp/src/whatsapp_channel.dart',
        'package:dartclaw_whatsapp/src/gowa_manager.dart',
        'package:dartclaw_signal/src/signal_channel.dart',
        'package:dartclaw_signal/src/signal_cli_manager.dart',
        'package:dartclaw_google_chat/src/google_chat_channel.dart',
        'package:dartclaw_google_chat/src/google_chat_webhook.dart',
        'package:dartclaw_google_chat/src/workspace_events_manager.dart',
      ];
      for (final marker in excludedLibraries) {
        expect(fullText.contains(marker), isTrue, reason: 'Positive control: $marker');
        expect(leanText.contains(marker), isFalse, reason: 'Lean retains $marker');
      }
      expect(lean.length, lessThan(full.length));
      print('Binary bytes: full=${full.length}, lean=${lean.length}');
      for (final name in ['serve', 'workflow']) {
        final refused = Process.runSync(p.join(buildDir.path, 'bin', 'dartclaw-workflow'), [name]);
        expect(refused.exitCode, 64);
        expect(refused.stderr, contains('Could not find a command named "$name".'));
      }
      for (final binaryName in ['dartclaw', 'dartclaw-workflow']) {
        final archive = p.join(buildDir.path, '$binaryName-v$version-${_hostOsName()}-${_hostArchName()}.tar.gz');
        final archiveSha = '$archive.sha256';
        final sums = p.join(buildDir.path, 'SHA256SUMS.txt');
        final binaryPath = p.join(buildDir.path, 'bin', binaryName);
        expect(File(binaryPath).existsSync(), isTrue);
        expect(File(archive).existsSync(), isTrue);
        expect(File(archiveSha).existsSync(), isTrue);
        expect(File(sums).existsSync(), isTrue);
        expect(
          buildDir.listSync().whereType<File>().any((file) => p.basename(file.path).startsWith('dartclaw-assets-')),
          isFalse,
        );

        final retiredCommand = Process.runSync(binaryPath, ['assets']);
        expect(retiredCommand.exitCode, 64);
        expect(retiredCommand.stderr, contains('Could not find a command named "assets".'));

        final entries = _tarEntries(archive);
        expect(entries, containsAll(['VERSION', 'bin/', 'bin/$binaryName', 'lib/']));
        expect(
          entries.any((entry) => entry.startsWith('lib/') && entry != 'lib/'),
          isTrue,
          reason: 'The verified native embedding libraries must remain packaged.',
        );
        expect(
          entries.where((entry) => p.basename(entry).toLowerCase().contains('sqlite')),
          isEmpty,
          reason: 'Release archives must not carry a SQLite native library.',
        );
        expect(entries.any((entry) => entry.startsWith('share/')), isFalse);

        final checksumLine = '${_hashFile(archive)}  ${p.basename(archive)}';
        expect(File(archiveSha).readAsStringSync().trim(), checksumLine);
        expect(File(sums).readAsLinesSync(), contains(checksumLine));
        expect(File(sums).readAsLinesSync(), hasLength(2));
        final versionResult = Process.runSync(binaryPath, ['--version']);
        expect(versionResult.exitCode, 0);
        expect((versionResult.stdout as String).trim(), dartclawVersion);
      }
    },
    skip: Platform.environment['DARTCLAW_NATIVE_ARCHIVE_CACHE'] == null
        ? 'A real release build requires the verified native archive cache.'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test('produces target-stamped stub archives without a bundled library', () {
    addTearDown(() {
      if (buildDir.existsSync()) buildDir.deleteSync(recursive: true);
    });
    final fixture = Directory.systemTemp.createTempSync('dartclaw-native-build-stub');
    addTearDown(() => fixture.deleteSync(recursive: true));
    final cache = Directory(p.join(fixture.path, 'cache'))..createSync();
    final manifest = File(p.join(fixture.path, 'manifest.json'));
    final bytes = utf8.encode('tiny native archive for a compile-free packaging test');
    final digest = sha256.convert(bytes).toString();
    final artifacts = <String, Object?>{};
    for (final target in ['macos-arm64', 'macos-x64', 'linux-x64', 'linux-arm64']) {
      final bundle = target == 'macos-x64' ? 'macos-x86_64' : target;
      final archive = 'llamadart-native-$bundle-v0.3.0.tar.gz';
      File(p.join(cache.path, archive)).writeAsBytesSync(bytes);
      artifacts[target] = {
        'bundle': bundle,
        'archive': archive,
        'url': 'https://example.test/$archive',
        'size': bytes.length,
        'sha256': digest,
      };
    }
    manifest.writeAsStringSync(
      jsonEncode({
        'release': 'v0.3.0',
        'repository': 'https://example.test/native',
        'model': {
          'basename': 'tiny-model.gguf',
          'url': 'https://example.test/tiny-model.gguf',
          'size': bytes.length,
          'sha256': digest,
        },
        'artifacts': artifacts,
      }),
    );
    for (final target in ['macos-arm64', 'macos-x64', 'linux-x64', 'linux-arm64']) {
      final result = Process.runSync(
        'bash',
        [buildScript],
        workingDirectory: repoRoot,
        environment: {
          'DARTCLAW_RELEASE_TARGET': target,
          'DARTCLAW_BUILD_SKIP_COMPILE': '1',
          'DARTCLAW_NATIVE_ARCHIVE_CACHE': cache.path,
          'DARTCLAW_NATIVE_MANIFEST': manifest.path,
        },
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      for (final binaryName in ['dartclaw', 'dartclaw-workflow']) {
        final archive = File(p.join(buildDir.path, '$binaryName-v$version-$target.tar.gz'));
        expect(archive.existsSync(), isTrue);
        expect(File('${archive.path}.sha256').existsSync(), isTrue);
        expect(File(p.join(buildDir.path, 'bin', binaryName)).existsSync(), isTrue);

        final entries = _tarEntries(archive.path);
        expect(entries, containsAll(['VERSION', 'bin/', 'bin/$binaryName']));
        // The compile stub emits no native library, so no lib/ is staged.
        expect(entries.any((entry) => entry.startsWith('lib/')), isFalse);
        expect(entries.any((entry) => entry.startsWith('share/')), isFalse);
        expect(File(p.join(buildDir.path, 'SHA256SUMS.txt')).readAsStringSync().trim().split('\n'), hasLength(2));
      }
    }
  });
}
