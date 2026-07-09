import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  AgentExecution createExecution({
    String id = 'ae-1',
    String? sessionId = 'sess-1',
    String provider = 'claude',
    String? model = 'claude-opus-4-7',
    String? workspaceDir = '/tmp/workspace',
    String? containerJson = '{"profile":"plain"}',
    int? budgetTokens = 50000,
    String? harnessMetaJson = '{"providerSessionId":"prov-1"}',
    DateTime? startedAt,
    DateTime? completedAt,
  }) {
    return AgentExecution(
      id: id,
      sessionId: sessionId,
      provider: provider,
      model: model,
      workspaceDir: workspaceDir,
      containerJson: containerJson,
      budgetTokens: budgetTokens,
      harnessMetaJson: harnessMetaJson,
      startedAt: startedAt ?? DateTime.parse('2026-04-19T00:00:00Z'),
      completedAt: completedAt,
    );
  }

  group('AgentExecution', () {
    test('round-trips through toJson and fromJson', () {
      final execution = createExecution(completedAt: DateTime.parse('2026-04-19T00:10:00Z'));

      final restored = AgentExecution.fromJson(execution.toJson());

      expect(restored, equals(execution));
      expect(restored.toJson(), equals(execution.toJson()));
    });

    test('copyWith can clear nullable fields', () {
      final execution = createExecution();

      final updated = execution.copyWith(
        sessionId: null,
        model: null,
        workspaceDir: null,
        containerJson: null,
        budgetTokens: null,
        harnessMetaJson: null,
        startedAt: null,
        completedAt: null,
      );

      expect(updated.sessionId, isNull);
      expect(updated.model, isNull);
      expect(updated.workspaceDir, isNull);
      expect(updated.containerJson, isNull);
      expect(updated.budgetTokens, isNull);
      expect(updated.harnessMetaJson, isNull);
      expect(updated.startedAt, isNull);
      expect(updated.completedAt, isNull);
    });

    test('toJson omits null optional fields', () {
      final execution = AgentExecution(id: 'ae-1', provider: 'codex');

      expect(execution.toJson(), equals({'id': 'ae-1', 'provider': 'codex'}));
    });

    test('source file stays task and workflow agnostic', () async {
      // AgentExecution lives in dartclaw_config. Resolve its source through the
      // package: URI mechanism so the lookup is independent of CWD and of where
      // `dart test` stages the precompiled kernel.
      final sourceUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_config/src/agent_execution.dart'));
      expect(sourceUri, isNotNull, reason: 'could not resolve package:dartclaw_config/src/agent_execution.dart');
      final source = File.fromUri(sourceUri!).readAsStringSync();

      expect(source, isNot(contains('/task/')));
      expect(source, isNot(contains('dartclaw_models')));
      expect(source, isNot(contains('workflow')));
    });
  });
}
