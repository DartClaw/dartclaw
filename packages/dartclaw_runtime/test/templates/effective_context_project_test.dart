import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('configured project names fall back to ID while the configured default wins', () async {
    final root = Directory.systemTemp.createTempSync('effective_context_project_');
    addTearDown(() => root.deleteSync(recursive: true));
    final named = Directory('${root.path}/named')..createSync();
    final fallback = Directory('${root.path}/fallback')..createSync();
    final service = ProjectServiceImpl(
      dataDir: root.path,
      projectConfig: ProjectConfig(
        definitions: {
          'named-id': ProjectDefinition(id: 'named-id', name: 'Human Name', localPath: named.path, isDefault: true),
          'fallback-id': ProjectDefinition(id: 'fallback-id', localPath: fallback.path),
        },
      ),
      credentials: const CredentialsConfig.defaults(),
    );
    await service.initialize();
    addTearDown(service.dispose);

    expect((await service.defaultProject).id, 'named-id');
    expect((await service.get('named-id'))?.name, 'Human Name');
    expect((await service.get('fallback-id'))?.name, 'fallback-id');
  });
}
