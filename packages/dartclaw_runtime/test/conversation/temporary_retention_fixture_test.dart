import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('inventory gives every private and shared durable sink a non-vacuous probe', () async {
    final decoded = jsonDecode(
      File(await resolveWorkspacePath('dev', 'testing', 'temporary-retention-inventory.json')).readAsStringSync(),
    );
    final surfaces = (decoded as Map<String, dynamic>)['surfaces'] as List<dynamic>;
    final ids = <String>{};
    for (final raw in surfaces) {
      final surface = raw as Map<String, dynamic>;
      expect(ids.add(surface['id'] as String), isTrue);
      expect((surface['negativeProbe'] as String).trim(), isNotEmpty);
      expect((surface['positiveControl'] as String).trim(), isNotEmpty);
      expect((surface['owner'] as String).trim(), isNotEmpty);
    }
    expect(
      ids,
      containsAll({
        'personal-memory',
        'daily-log',
        'shared-wiki',
        'shared-kg',
        'knowledge-inbox',
        'memory-lexical-index',
        'memory-vector-index',
        'conversation-lexical-index',
        'conversation-vector-index',
        'audit-log',
        'replay',
      }),
    );
  });

  test('live fixture attempts every write shape and rechecks all sinks after rebuild', () async {
    final runner = File(await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/run.sh'))
        .readAsStringSync();
    final fixture = File(
      await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/temporary_conversation_e2e.sh'),
    ).readAsStringSync();
    final sinkChecks = File(
      await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/temporary_sink_checks.py'),
    ).readAsStringSync();

    expect(runner, contains('temporary_conversation_e2e.sh" eof "\${EVIDENCE_ROOT}/postgres-confirmed-end" postgres'));
    expect(runner, contains('temporary_conversation_e2e.sh" graceful "\${EVIDENCE_ROOT}/postgres-graceful" postgres'));
    expect(runner, contains('temporary_conversation_e2e.sh" sigkill "\${EVIDENCE_ROOT}/postgres-sigkill" postgres'));
    expect(fixture, contains('TEMPORARY_DURABLE_SINK_MARKER'));
    expect(fixture, contains('memory_observe exactly once'));
    expect(fixture, contains('wiki_write tool directly'));
    expect(fixture, contains('mcp__dartclaw__wiki_write'));
    expect(fixture, contains('temporary-malformed-publication.json'));
    expect(fixture, contains('knowledge_inbox_ingest'));
    expect(fixture, contains('ordinary-wiki-control'));
    expect(fixture, contains('ORDINARY_KG_CONTROL'));
    expect(fixture, contains('ORDINARY_INBOX_CONTROL'));
    expect(fixture, contains('rebuild-index --json'));
    expect(fixture, contains('run_sink_checks after-rebuild'));
    expect(fixture, contains('run_sink_checks after-restart'));
    expect(fixture, contains(r'''if rg -uuu -q "$TEMPORARY_MARKER_PATTERN" "$DATA_DIR"'''));

    for (final surface in const [
      'personal-memory',
      'daily-log',
      'shared-wiki',
      'shared-kg',
      'knowledge-inbox',
      'memory-lexical-index',
      'memory-vector-index',
      'conversation-lexical-index',
      'conversation-vector-index',
      'audit-log',
      'replay',
    ]) {
      expect(sinkChecks, contains("'$surface'"), reason: '$surface is not checked by the sink enumerator');
    }
    expect(sinkChecks, contains('ORDINARY_MEMORY_CONTROL'));
    expect(sinkChecks, contains('ORDINARY_WIKI_CONTROL'));
    expect(sinkChecks, contains('ORDINARY_KG_CONTROL'));
    expect(sinkChecks, contains('ORDINARY_INBOX_CONTROL'));
  });

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
