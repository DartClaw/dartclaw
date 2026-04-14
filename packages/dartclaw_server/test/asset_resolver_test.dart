import 'dart:io';

import 'package:dartclaw_server/src/asset_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_asset_resolver_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('finds assets under share/dartclaw relative to the resolved executable', () {
    final prefixDir = Directory(p.join(tempDir.path, 'prefix'))..createSync(recursive: true);
    final shareRoot = Directory(p.join(prefixDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
    Directory(p.join(shareRoot.path, 'templates')).createSync();
    Directory(p.join(shareRoot.path, 'static')).createSync();
    Directory(p.join(shareRoot.path, 'skills')).createSync();
    Directory(p.join(shareRoot.path, 'workflows')).createSync();

    final resolver = AssetResolver(resolvedExecutable: p.join(prefixDir.path, 'bin', 'dartclaw'));
    final resolved = resolver.resolve();

    expect(resolved, isNotNull);
    expect(resolved!.root, shareRoot.path);
    expect(resolved.templatesDir, p.join(shareRoot.path, 'templates'));
    expect(resolved.staticDir, p.join(shareRoot.path, 'static'));
    expect(resolved.skillsDir, p.join(shareRoot.path, 'skills'));
    expect(resolved.workflowsDir, p.join(shareRoot.path, 'workflows'));
  });

  test('falls back to the binary directory when the share layout is incomplete', () {
    final prefixDir = Directory(p.join(tempDir.path, 'prefix'))..createSync(recursive: true);
    final shareRoot = Directory(p.join(prefixDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
    Directory(p.join(shareRoot.path, 'static')).createSync();

    final binaryDir = Directory(p.join(prefixDir.path, 'bin'))..createSync(recursive: true);
    Directory(p.join(binaryDir.path, 'templates')).createSync();
    Directory(p.join(binaryDir.path, 'static')).createSync();

    final resolver = AssetResolver(resolvedExecutable: p.join(binaryDir.path, 'dartclaw'));
    final resolved = resolver.resolve();

    expect(resolved, isNotNull);
    expect(resolved!.root, binaryDir.path);
  });

  test('returns null when no candidate root has both templates and static', () {
    final prefixDir = Directory(p.join(tempDir.path, 'prefix'))..createSync(recursive: true);
    final shareRoot = Directory(p.join(prefixDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
    Directory(p.join(shareRoot.path, 'static')).createSync();

    final binaryDir = Directory(p.join(prefixDir.path, 'bin'))..createSync(recursive: true);
    Directory(p.join(binaryDir.path, 'templates')).createSync();

    final homeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final resolver = AssetResolver(resolvedExecutable: p.join(binaryDir.path, 'dartclaw'), homeDir: homeDir.path);

    expect(resolver.resolve(), isNull);
  });
}
