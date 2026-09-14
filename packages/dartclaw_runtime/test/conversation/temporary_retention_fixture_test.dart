import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('inventory gives every durable surface an independent non-vacuous probe', () async {
    final decoded = jsonDecode(
      File(await resolveWorkspacePath('dev', 'testing', 'temporary-retention-inventory.json')).readAsStringSync(),
    );
    final surfaces = (decoded as Map<String, dynamic>)['surfaces'] as List<dynamic>;
    expect(surfaces, hasLength(greaterThanOrEqualTo(14)));
    final ids = <String>{};
    for (final raw in surfaces) {
      final surface = raw as Map<String, dynamic>;
      expect(ids.add(surface['id'] as String), isTrue);
      expect((surface['negativeProbe'] as String).trim(), isNotEmpty);
      expect((surface['positiveControl'] as String).trim(), isNotEmpty);
      expect((surface['owner'] as String).trim(), isNotEmpty);
    }
    expect(ids, containsAll(['provider-home', 'browser-storage', 'replay', 'audit-log', 'vector-index']));
  });

  test('deferred matrix drives the assembled server and cannot accept caller command placeholders', () async {
    final runner = File(await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/run.sh'))
        .readAsStringSync();
    final fixture = File(
      await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/temporary_conversation_e2e.sh'),
    ).readAsStringSync();
    final sinkChecks = File(
      await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/temporary_sink_checks.py'),
    ).readAsStringSync();
    expect(runner, isNot(contains('DARTCLAW_TEMPORARY_PROVIDER_COMMAND')));
    expect(runner, isNot(contains('DARTCLAW_TEMPORARY_BROWSER_COMMAND')));
    expect(fixture, contains('build/bin/dartclaw'));
    expect(fixture, isNot(contains('dart run apps/dartclaw_cli')));
    expect(fixture, contains("send_turn 'TEMPORARY_TURN_ONE' 'temporary-turn-one'"));
    expect(fixture, contains("send_turn 'TEMPORARY_TURN_TWO' 'temporary-turn-two'"));
    expect(fixture, contains("status.get('turn_id') == turn_id"));
    expect(fixture, contains("status.get('state') == 'completed'"));
    expect(fixture, contains("assert row['Config']['Cmd'] == ['cat']"));
    expect(fixture, contains(r'''kill -9 "$SERVER_PID"'''));
    expect(fixture, contains(r'''[ "$MODE" = graceful ]'''));
    expect(fixture, contains('end-temporary'));
    expect(fixture, contains('pg_dump --data-only'));
    expect(fixture, contains('temporary_browser_checks.sh'));
    expect(fixture, contains('temporary_sink_checks.py'));
    expect(fixture, contains('search download-model --json'));
    expect(fixture, contains('codex login status'));
    expect(fixture, contains('temporary_history_setup'));
    expect(fixture, contains('temporary_queue_setup'));
    expect(fixture, contains('run_sink_checks after-queue'));
    expect(fixture, contains('run_sink_checks after-restart'));
    expect(fixture, contains('BRANCH_SESSION_ID'));
    expect(fixture, contains('bash dev/tools/build.sh'));
    expect(
      fixture,
      contains(
        '--run-skipped -t integration packages/dartclaw_runtime/test/container/temporary_container_manager_live_test.dart',
      ),
    );
    expect(sinkChecks, contains('ORDINARY_ATTACHMENT_CONTROL'));
    expect(sinkChecks, contains('FROM conversation_chunks ORDER BY id'));
    expect(sinkChecks, contains('FROM conversation_vectors ORDER BY document_id, chunk_index'));
    expect(sinkChecks, isNot(contains("results['browser-storage']")));
    expect(fixture, contains('ordinary-replay-control'));
    expect(fixture, contains(r'''if rg -uuu -q "$TEMPORARY_MARKER_PATTERN"'''));
    expect(fixture, isNot(contains(r'''  ! rg -uuu -q''')));
    for (final backend in const ['sqlite', 'postgres']) {
      for (final boundary in const ['eof', 'graceful', 'sigkill']) {
        expect(runner, contains('temporary_conversation_e2e.sh" $boundary "\${EVIDENCE_ROOT}/$backend-'));
      }
    }
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
