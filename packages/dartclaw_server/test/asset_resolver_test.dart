import 'dart:io';

import 'package:dartclaw_server/src/asset_resolver.dart';
import 'package:dartclaw_server/src/version.dart';
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
    final resolved = resolver.resolveAssets(const AssetResolutionRequest.noConfiguredAssets());

    expect(resolved, isNotNull);
    expect(resolved!.root, shareRoot.path);
    expect(resolved.source, AssetSource.installedAlongsideBinary);
    expect(resolved.templatesDir, p.join(shareRoot.path, 'templates'));
    expect(resolved.staticDir, p.join(shareRoot.path, 'static'));
    expect(resolved.skillsDir, p.join(shareRoot.path, 'skills'));
    expect(resolved.workflowsDir, p.join(shareRoot.path, 'workflows'));
    expect(resolved.rootSkillsDir, p.join(shareRoot.path, 'skills'));
    expect(resolved.rootWorkflowsDir, p.join(shareRoot.path, 'workflows'));
  });

  test('falls back to the binary directory when the share layout is incomplete', () {
    final prefixDir = Directory(p.join(tempDir.path, 'prefix'))..createSync(recursive: true);
    final shareRoot = Directory(p.join(prefixDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
    Directory(p.join(shareRoot.path, 'static')).createSync();

    final binaryDir = Directory(p.join(prefixDir.path, 'bin'))..createSync(recursive: true);
    Directory(p.join(binaryDir.path, 'templates')).createSync();
    Directory(p.join(binaryDir.path, 'static')).createSync();

    final resolver = AssetResolver(resolvedExecutable: p.join(binaryDir.path, 'dartclaw'));
    final resolved = resolver.resolveAssets(const AssetResolutionRequest.noConfiguredAssets());

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

    expect(resolver.resolveAssets(const AssetResolutionRequest.noConfiguredAssets()), isNull);
  });

  group('resolveAssets precedence', () {
    ({AssetResolver resolver, String cacheRoot, String srcTemplates, String srcStatic}) scenario({
      String? cacheMarkerVersion,
    }) {
      final home = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
      final cacheRoot = Directory(p.join(home.path, '.dartclaw', 'assets', 'v$dartclawVersion'))
        ..createSync(recursive: true);
      Directory(p.join(cacheRoot.path, 'templates')).createSync();
      Directory(p.join(cacheRoot.path, 'static')).createSync();
      if (cacheMarkerVersion != null) {
        File(p.join(cacheRoot.path, 'VERSION')).writeAsStringSync('$cacheMarkerVersion\n');
      }

      final src = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
      final srcTemplates = Directory(p.join(src.path, 'packages', 'dartclaw_server', 'lib', 'src', 'templates'))
        ..createSync(recursive: true);
      final srcStatic = Directory(p.join(src.path, 'packages', 'dartclaw_server', 'lib', 'src', 'static'))
        ..createSync(recursive: true);

      // Executable lives somewhere with no adjacent share/ layout, so the only
      // install/cache candidate is the home cache.
      final resolver = AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'nowhere', 'bin', 'dartclaw'),
        homeDir: home.path,
        version: dartclawVersion,
      );
      return (
        resolver: resolver,
        cacheRoot: cacheRoot.path,
        srcTemplates: srcTemplates.path,
        srcStatic: srcStatic.path,
      );
    }

    AssetResolutionRequest request(
      ({AssetResolver resolver, String cacheRoot, String srcTemplates, String srcStatic}) s, {
      required bool explicit,
      required bool dev,
    }) => AssetResolutionRequest(
      configuredTemplatesDir: s.srcTemplates,
      configuredStaticDir: s.srcStatic,
      explicitlyConfigured: explicit,
      devMode: dev,
    );

    test('explicit --source-dir beats a present (same-version) cache — the bug fix', () {
      final s = scenario(cacheMarkerVersion: dartclawVersion);
      final r = s.resolver.resolveAssets(request(s, explicit: true, dev: false))!;
      expect(r.source, AssetSource.explicitConfig);
      expect(r.templatesDir, s.srcTemplates);
      expect(r.workflowAssetPolicy, WorkflowAssetPolicy.sourceTreeFallback);
      expect(r.skillsDir, endsWith(p.join('packages', 'dartclaw_workflow', 'skills')));
      expect(r.rootSkillsDir, isNull);
      expect(
        r.workflowsDir,
        endsWith(p.join('packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions')),
      );
      expect(r.rootWorkflowsDir, isNull);
    });

    test('--dev beats a present cache even without an explicit dir flag', () {
      final s = scenario(cacheMarkerVersion: dartclawVersion);
      final r = s.resolver.resolveAssets(request(s, explicit: false, dev: true))!;
      expect(r.source, AssetSource.devSourceTree);
      expect(r.templatesDir, s.srcTemplates);
    });

    test('without explicit/dev intent, a same-version cache is used (production path)', () {
      final s = scenario(cacheMarkerVersion: dartclawVersion);
      final r = s.resolver.resolveAssets(request(s, explicit: false, dev: false))!;
      expect(r.source, AssetSource.downloadedCache);
      expect(r.declaredVersion, dartclawVersion);
      expect(r.skillsDir, p.join(s.cacheRoot, 'skills'));
      expect(r.workflowsDir, p.join(s.cacheRoot, 'workflows'));
      expect(r.rootSkillsDir, p.join(s.cacheRoot, 'skills'));
      expect(r.rootWorkflowsDir, p.join(s.cacheRoot, 'workflows'));
      expect(r.workflowAssetPolicy, WorkflowAssetPolicy.resolvedDirectories);
    });

    test('a version-mismatched cache is skipped, falling through to the source-tree default', () {
      final s = scenario(cacheMarkerVersion: '0.0.1-stale');
      final r = s.resolver.resolveAssets(request(s, explicit: false, dev: false))!;
      expect(r.source, AssetSource.sourceTreeDefault);
      expect(r.templatesDir, s.srcTemplates);
    });

    test('a markerless cache is skipped, falling through to the source-tree default', () {
      final s = scenario();
      final r = s.resolver.resolveAssets(request(s, explicit: false, dev: false))!;
      expect(r.source, AssetSource.sourceTreeDefault);
      expect(r.templatesDir, s.srcTemplates);
    });

    test('an empty VERSION cache is skipped, falling through to the source-tree default', () {
      final s = scenario(cacheMarkerVersion: '');
      final r = s.resolver.resolveAssets(request(s, explicit: false, dev: false))!;
      expect(r.source, AssetSource.sourceTreeDefault);
      expect(r.templatesDir, s.srcTemplates);
    });

    test('returns null (caller must download) when nothing is on disk', () {
      final emptyHome = Directory(p.join(tempDir.path, 'empty-home'))..createSync(recursive: true);
      final resolver = AssetResolver(
        resolvedExecutable: p.join(tempDir.path, 'nowhere', 'bin', 'dartclaw'),
        homeDir: emptyHome.path,
      );
      final req = AssetResolutionRequest(
        configuredTemplatesDir: p.join(tempDir.path, 'absent', 'templates'),
        configuredStaticDir: p.join(tempDir.path, 'absent', 'static'),
        explicitlyConfigured: true,
        devMode: true,
      );
      expect(resolver.resolveAssets(req), isNull);
    });
  });
}
