import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP permission handler', () {
    late Directory workspace;
    late FakeAcpProcess process;
    late List<AcpReverseCallAuditEvent> auditEvents;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('dartclaw_acp_permission_');
      process = FakeAcpProcess();
      auditEvents = [];
    });

    tearDown(() async {
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    test('approved and denied session/request_permission outcomes use the approval seam', () async {
      var allow = true;
      final harness = AcpHarness(
        cwd: workspace.path,
        executable: 'goose',
        arguments: const ['acp'],
        permissionDecision: (request) async => AcpPermissionResult(granted: allow, reason: allow ? null : 'denied'),
        onReverseCallAudit: auditEvents.add,
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      );
      addTearDown(harness.dispose);
      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      process.sendHostRequest(100, 'session/request_permission', {'operation': 'shell'});
      final approved = await process.waitForResponse(100);
      allow = false;
      process.sendHostRequest(101, 'session/request_permission', {'operation': 'file_write'});
      final denied = await process.waitForResponse(101);

      expect(approved['result'], containsPair('granted', true));
      expect(denied['result'], containsPair('granted', false));
      expect(denied['result'], containsPair('reason', 'denied'));
      expect(auditEvents.map((event) => event.rawProviderToolName), [
        'session/request_permission',
        'session/request_permission',
      ]);
    });

    test('approval handler exceptions fail closed', () async {
      final harness = AcpHarness(
        cwd: workspace.path,
        executable: 'goose',
        arguments: const ['acp'],
        permissionDecision: (request) async => throw StateError('boom'),
        onReverseCallAudit: auditEvents.add,
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      );
      addTearDown(harness.dispose);
      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      process.sendHostRequest(200, 'session/request_permission', {'operation': 'file_write'});
      final response = await process.waitForResponse(200);

      expect(response['result'], containsPair('granted', false));
      expect(response['result']['reason'], contains('Permission handler error'));
    });
  });
}
