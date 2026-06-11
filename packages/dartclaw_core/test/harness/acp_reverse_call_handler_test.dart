import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'acp_test_support.dart';
import 'harness_test_support.dart';

void main() {
  group('ACP reverse-call handlers', () {
    late Directory workspace;
    late FakeAcpProcess acpProcess;
    late RecordingGuard guard;
    late List<AcpReverseCallAuditEvent> auditEvents;
    late AcpHarness harness;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('dartclaw_acp_reverse_');
      acpProcess = FakeAcpProcess();
      guard = RecordingGuard();
      auditEvents = [];
      harness = AcpHarness(
        cwd: workspace.path,
        executable: 'goose',
        arguments: const ['acp'],
        guardChain: GuardChain(guards: [guard]),
        onReverseCallAudit: auditEvents.add,
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                acpProcess,
      );
      final startFuture = harness.start();
      await acpProcess.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;
    });

    tearDown(() async {
      await harness.dispose();
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    test('ACP file handlers map canonical tools, preserve raw names, and apply workspace jail', () async {
      await File(p.join(workspace.path, 'allowed.txt')).writeAsString('visible');

      acpProcess.sendHostRequest(100, 'fs/read_text_file', {'path': 'allowed.txt'});
      final readResponse = await acpProcess.waitForResponse(100);

      expect(readResponse['result'], containsPair('content', 'visible'));
      expect(guard.lastContext!.toolName, 'file_read');
      expect(guard.lastContext!.rawProviderToolName, 'fs/read_text_file');
      expect(
        guard.lastContext!.toolInput!['path'],
        File(p.join(workspace.path, 'allowed.txt')).resolveSymbolicLinksSync(),
      );

      acpProcess.sendHostRequest(101, 'fs/write_text_file', {'path': 'created.txt', 'content': 'new'});
      final writeResponse = await acpProcess.waitForResponse(101);

      expect(writeResponse['result'], containsPair('ok', true));
      expect(File(p.join(workspace.path, 'created.txt')).readAsStringSync(), 'new');
      expect(guard.lastContext!.toolName, 'file_write');
      expect(guard.lastContext!.rawProviderToolName, 'fs/write_text_file');

      acpProcess.sendHostRequest(102, 'fs/read_text_file', {'path': '../outside.txt'});
      final traversalResponse = await acpProcess.waitForResponse(102);

      expect(traversalResponse['error'], isNotNull);
    });

    test('denied ACP file reads and writes fail closed without file side effects', () async {
      await harness.dispose();
      guard = RecordingGuard(verdict: GuardVerdict.block('blocked by test'));
      acpProcess = FakeAcpProcess();
      harness = AcpHarness(
        cwd: workspace.path,
        executable: 'goose',
        arguments: const ['acp'],
        guardChain: GuardChain(guards: [guard]),
        onReverseCallAudit: auditEvents.add,
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                acpProcess,
      );
      final startFuture = harness.start();
      await acpProcess.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;
      await File(p.join(workspace.path, 'secret.txt')).writeAsString('secret');

      acpProcess.sendHostRequest(200, 'fs/read_text_file', {'path': 'secret.txt'});
      final readResponse = await acpProcess.waitForResponse(200);
      acpProcess.sendHostRequest(201, 'fs/write_text_file', {'path': 'denied.txt', 'content': 'must not land'});
      final writeResponse = await acpProcess.waitForResponse(201);

      expect(readResponse['result'], containsPair('noAccess', true));
      expect((readResponse['result'] as Map).containsKey('content'), isFalse);
      expect(writeResponse['result'], containsPair('noAccess', true));
      expect(File(p.join(workspace.path, 'denied.txt')).existsSync(), isFalse);
      expect(guard.contexts.map((context) => context.toolName), ['file_read', 'file_write']);
      expect(guard.contexts.map((context) => context.rawProviderToolName), ['fs/read_text_file', 'fs/write_text_file']);
    });

    test('malformed reverse-call payloads fail before guard and side effects', () async {
      acpProcess.sendHostRequest(300, 'fs/read_text_file', {});
      acpProcess.sendHostRequest(301, 'fs/write_text_file', {'path': 'x.txt'});
      acpProcess.sendHostRequest(302, 'terminal/create', {
        'command': 'echo ok',
        'env': {'BAD': 1},
      });
      acpProcess.sendHostRequest(303, 'terminal/output', {'terminalId': 7});

      final responses = [
        await acpProcess.waitForResponse(300),
        await acpProcess.waitForResponse(301),
        await acpProcess.waitForResponse(302),
        await acpProcess.waitForResponse(303),
      ];

      expect(responses, everyElement(contains('error')));
      expect(guard.contexts, isEmpty);
      expect(workspace.listSync(), isEmpty);
    });

    test('symlink traversal fails before guard, filesystem, or terminal side effects', () async {
      final outside = await Directory.systemTemp.createTemp('dartclaw_acp_outside_');
      addTearDown(() async {
        if (outside.existsSync()) {
          await outside.delete(recursive: true);
        }
      });
      await File(p.join(outside.path, 'secret.txt')).writeAsString('outside');
      await Link(p.join(workspace.path, 'outside-link')).create(outside.path);
      guard.contexts.clear();

      acpProcess.sendHostRequest(350, 'fs/read_text_file', {'path': 'outside-link/secret.txt'});
      acpProcess.sendHostRequest(351, 'fs/write_text_file', {'path': 'outside-link/created.txt', 'content': 'escape'});
      acpProcess.sendHostRequest(352, 'terminal/create', {'command': 'pwd', 'cwd': 'outside-link'});

      final responses = [
        await acpProcess.waitForResponse(350),
        await acpProcess.waitForResponse(351),
        await acpProcess.waitForResponse(352),
      ];

      expect(responses, everyElement(contains('error')));
      expect(guard.contexts, isEmpty);
      expect(File(p.join(outside.path, 'created.txt')).existsSync(), isFalse);
    });

    test('session/request_permission uses approval seam and preserves raw audit method', () async {
      await harness.dispose();
      acpProcess = FakeAcpProcess();
      harness = AcpHarness(
        cwd: workspace.path,
        executable: 'goose',
        arguments: const ['acp'],
        guardChain: GuardChain(guards: [guard]),
        permissionDecision: (request) async => const AcpPermissionResult(granted: false, reason: 'denied'),
        onReverseCallAudit: auditEvents.add,
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                acpProcess,
      );
      final startFuture = harness.start();
      await acpProcess.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      acpProcess.sendHostRequest(400, 'session/request_permission', {'operation': 'file_write'});
      final response = await acpProcess.waitForResponse(400);

      expect(response['result'], containsPair('granted', false));
      expect(response['result'], containsPair('reason', 'denied'));
      expect(auditEvents.last.rawProviderToolName, 'session/request_permission');
      expect(auditEvents.last.canonicalToolName, 'file_write');
    });
  });
}
