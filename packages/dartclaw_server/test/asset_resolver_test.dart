import 'dart:io';

import 'package:dartclaw_server/src/asset_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String templatesDir;
  late String staticDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_asset_resolver_test_');
    final root = p.join(tempDir.path, 'repo');
    final templates = Directory(p.join(root, 'packages', 'dartclaw_server', 'lib', 'src', 'templates'))
      ..createSync(recursive: true);
    final staticAssets = Directory(p.join(root, 'packages', 'dartclaw_server', 'lib', 'src', 'static'))
      ..createSync(recursive: true);
    templatesDir = templates.path;
    staticDir = staticAssets.path;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  AssetResolutionRequest request({required bool explicit, required bool dev}) => AssetResolutionRequest(
    configuredTemplatesDir: templatesDir,
    configuredStaticDir: staticDir,
    explicitlyConfigured: explicit,
    devMode: dev,
  );

  test('explicit asset directories win', () {
    final resolved = AssetResolver().resolveAssets(request(explicit: true, dev: false));

    expect(resolved.source, AssetSource.explicitConfig);
    expect(resolved.templatesDir, templatesDir);
    expect(resolved.staticDir, staticDir);
  });

  test('dev source tree wins when assets are not explicitly configured', () {
    final resolved = AssetResolver().resolveAssets(request(explicit: false, dev: true));

    expect(resolved.source, AssetSource.devSourceTree);
  });

  test('source-tree default wins ahead of embedded', () {
    final resolved = AssetResolver().resolveAssets(request(explicit: false, dev: false));

    expect(resolved.source, AssetSource.sourceTreeDefault);
    expect(resolved.skillsDir, endsWith(p.join('packages', 'dartclaw_workflow', 'skills')));
    expect(
      resolved.workflowsDir,
      endsWith(p.join('packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions')),
    );
  });

  test('embedded is the terminal fallback without filesystem assets', () {
    final resolved = AssetResolver().resolveAssets(
      AssetResolutionRequest(
        configuredTemplatesDir: p.join(tempDir.path, 'missing', 'templates'),
        configuredStaticDir: p.join(tempDir.path, 'missing', 'static'),
        explicitlyConfigured: false,
        devMode: false,
      ),
    );

    expect(resolved.source, AssetSource.embedded);
    expect(resolved.templatesDir, isNull);
    expect(resolved.staticDir, isNull);
    expect(resolved.skillsDir, isNull);
    expect(resolved.workflowsDir, isNull);
    expect(resolved.describe(), 'embedded');
  });
}
