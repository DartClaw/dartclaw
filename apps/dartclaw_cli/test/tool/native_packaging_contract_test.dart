import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../../dev/tools/stage_native_build_workspace.dart' as workspace_stage;

void main() {
  final root = _repoRoot();
  final posix = File(p.join(root, 'dev', 'tools', 'build.sh')).readAsStringSync();
  final windows = File(p.join(root, 'dev', 'tools', 'build_windows.ps1')).readAsStringSync();
  final stageTool = File(p.join(root, 'dev', 'tools', 'stage_native_build_workspace.dart')).readAsStringSync();

  test('verified preparation precedes every release compiler and uses a detached hook workspace', () {
    _expectBuildContract(posix, windows);
    expect(stageTool, contains("'        - llama_cpp\\n'"));
    expect(File(p.join(root, 'pubspec.yaml')).readAsStringSync(), isNot(contains('llamadart_native_path')));
    expect(posix.indexOf('native_artifact_preparation.dart'), lessThan(posix.indexOf('for binary_name in')));
    expect(windows.indexOf('native_artifact_preparation.dart'), lessThan(windows.indexOf(r'foreach ($binary')));
    expect(
      posix,
      contains(r'''--hook-root "$native_hook_root" \
    --manifest "$NATIVE_MANIFEST"'''),
    );
    expect(
      windows,
      contains(r'''--hook-root $nativeHookRoot `
      --manifest $manifestPath'''),
    );
    expect(posix, isNot(contains('--release v0.3.0')));
    expect(windows, isNot(contains(r'--release $nativeManifest.release')));
  });

  test('source mutations cannot bypass verification or broaden the selected runtime', () {
    expect(
      () => _expectBuildContract(posix.replaceFirst('native_artifact_preparation.dart', 'unchecked.dart'), windows),
      throwsStateError,
    );
    expect(
      () => _expectBuildContract(posix, windows.replaceFirst('native_artifact_preparation.dart', 'unchecked.dart')),
      throwsStateError,
    );
  });

  test('operation-local workspace carries exact hook inputs without changing its source', () async {
    final source = Directory.systemTemp.createTempSync('dartclaw-native-workspace-source');
    final destination = Directory.systemTemp.createTempSync('dartclaw-native-workspace-parent');
    destination.deleteSync();
    addTearDown(() {
      if (source.existsSync()) source.deleteSync(recursive: true);
      if (destination.existsSync()) destination.deleteSync(recursive: true);
    });
    File(p.join(source.path, 'pubspec.yaml')).writeAsStringSync('name: root\nworkspace:\n  - apps/dartclaw_cli\n');
    File(p.join(source.path, 'pubspec.lock')).writeAsStringSync('# lock\n');
    final app = Directory(p.join(source.path, 'apps', 'dartclaw_cli'))..createSync(recursive: true);
    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: app\nresolution: workspace\n');
    Directory(p.join(app.path, 'lib')).createSync();
    File(p.join(app.path, 'lib', 'app.dart')).writeAsStringSync('void value() {}\n');
    Directory(p.join(app.path, 'tool')).createSync();
    File(p.join(app.path, 'tool', 'probe.dart')).writeAsStringSync('void main() {}\n');
    const digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final manifest = File(p.join(source.path, 'native-artifacts.json'))
      ..writeAsStringSync(
        jsonEncode({
          'release': 'v9.8.7',
          'repository': 'https://example.test/custom-native',
          'model': {'basename': 'model.gguf', 'url': 'https://example.test/model.gguf', 'size': 1, 'sha256': digest},
          'artifacts': {
            'macos-arm64': {
              'bundle': 'macos-arm64',
              'archive': 'llamadart-native-macos-arm64-v9.8.7.tar.gz',
              'url': 'https://example.test/llamadart-native-macos-arm64-v9.8.7.tar.gz',
              'size': 1,
              'sha256': digest,
            },
          },
        }),
      );

    await workspace_stage.main([
      '--source',
      source.path,
      '--destination',
      destination.path,
      '--hook-root',
      p.join(source.path, 'verified hook'),
      '--manifest',
      manifest.path,
    ]);
    expect(
      File(p.join(destination.path, 'apps', 'dartclaw_cli', 'tool', 'probe.dart')).readAsStringSync(),
      'void main() {}\n',
    );
    final staged = File(p.join(destination.path, 'pubspec.yaml')).readAsStringSync();
    final hookRoot = Directory(p.join(source.path, 'verified hook')).absolute.uri.toString();
    expect(
      staged,
      contains('llamadart_native_path: ${jsonEncode(hookRoot)}'),
      reason: 'The upstream hook must receive a file URI so Windows drive letters are not parsed as URI schemes.',
    );
    expect(staged, contains('llamadart_native_tag: "v9.8.7"'));
    expect(staged, contains('llamadart_native_repository: "https://example.test/custom-native"'));
    expect(staged, contains('llamadart_native_runtimes:\n        - llama_cpp'));
    expect(
      File(p.join(source.path, 'pubspec.yaml')).readAsStringSync(),
      'name: root\nworkspace:\n  - apps/dartclaw_cli\n',
    );
  });

  test('packaging keeps native libraries discoverable from each binary', () {
    expect(RegExp(r'for binary_name in dartclaw dartclaw-workflow').hasMatch(posix), isTrue);
    expect(posix, contains(r'cp -R "$BUILD_DIR/lib" "$platform_stage/lib"'));
    expect(posix, isNot(contains('native_embedding_probe')));
    expect(posix, isNot(contains('embeddinggemma')));
    expect(posix, isNot(contains('share/')));

    expect(windows, contains("@{ Name = 'dartclaw'; Entry = 'dartclaw' }"));
    expect(windows, contains("@{ Name = 'dartclaw-workflow'; Entry = 'dartclaw_workflow' }"));
    expect(
      windows,
      contains(r"Copy-Item -LiteralPath $nativeLibraryRoot -Destination (Join-Path $stage 'lib') -Recurse"),
    );
    expect(windows, contains('function Get-WindowsRuntimeLibraryFiles'));
    expect(windows, contains(r"Where-Object { $_.Name -notin @('sqlite3.dll', 'llamadart.dll') }"));
    expect(windows, contains(r"Copy-Item -LiteralPath $runtimeLibrary.FullName -Destination (Join-Path $stage 'bin')"));
    expect(windows, contains(r"'bin/' + $_.Name"));
    expect(windows, contains("throw 'Windows artifact validation failed: unexpected share/ sidecar.'"));
    expect(windows, isNot(contains('native_embedding_probe')));
    expect(windows, isNot(contains('embeddinggemma')));
  });
}

void _expectBuildContract(String posix, String windows) {
  for (final source in [posix, windows]) {
    if (!source.contains('native_artifact_preparation.dart') || !source.contains('stage_native_build_workspace.dart')) {
      throw StateError('release build bypassed verified native hook staging');
    }
  }
}

String _repoRoot() {
  var current = Directory.current.absolute.path;
  while (!File(p.join(current, 'dev', 'tools', 'build.sh')).existsSync()) {
    final parent = p.dirname(current);
    if (parent == current) throw StateError('Repository root not found');
    current = parent;
  }
  return current;
}
