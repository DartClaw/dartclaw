import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('the exact live fixture YAML parses as mediated Codex with hybrid vectors', () async {
    final root = Directory.systemTemp.createTempSync('temporary-fixture-config-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(
      await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/temporary_conversation.yaml'),
    ).readAsStringSync();
    final config = DartclawConfig.load(
      configPath: 'temporary_conversation.yaml',
      fileReader: (_) => source,
      env: {'HOME': root.path},
      cliOverrides: {'port': '4567', 'data_dir': root.path, 'source_dir': Directory.current.path},
      resolveStoredCredentials: false,
    );

    expect(config.server.port, 4567);
    expect(config.server.dataDir, root.path);
    expect(config.agent.provider, 'codex');
    expect(config.agent.execution, ExecutionMode.container);
    expect(config.providers.entries['codex']?.executable, 'codex');
    expect(config.container.declaredEnabled, isTrue);
    expect(config.search.backend, 'hybrid');
    expect(config.search.embedding.provider, EmbeddingProviderKind.local);
    expect(config.search.embedding.model, 'embeddinggemma-300M-Q8_0.gguf');
    expect(config.search.embedding.endpoint, isNull);
    expect(config.search.embedding.credential, isNull);
    expect(config.warnings.where((warning) => warning.startsWith('Unknown config key:')), isEmpty);
  });
}
