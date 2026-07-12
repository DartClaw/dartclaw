import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/harness/acp_reverse_call_handlers.dart' show AcpReverseCallHandlers;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';
import 'harness_test_support.dart';

void main() {
  group('ACP terminal handlers', () {
    late Directory workspace;
    late FakeAcpProcess acpProcess;
    late RecordingGuard guard;
    late List<CapturingFakeProcess> terminalProcesses;
    late List<Map<String, String>?> capturedEnvironments;
    late List<String?> capturedWorkingDirectories;
    late List<AcpReverseCallAuditEvent> auditEvents;
    late AcpHarness harness;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('dartclaw_acp_terminal_');
      acpProcess = FakeAcpProcess();
      guard = RecordingGuard();
      terminalProcesses = [];
      capturedEnvironments = [];
      capturedWorkingDirectories = [];
      auditEvents = [];
      harness = _harness(
        workspace: workspace,
        acpProcess: acpProcess,
        guard: guard,
        auditEvents: auditEvents,
        terminalProcesses: terminalProcesses,
        capturedEnvironments: capturedEnvironments,
        capturedWorkingDirectories: capturedWorkingDirectories,
      );
      final startFuture = harness.start();
      await acpProcess.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;
    });

    tearDown(() async {
      for (final terminal in terminalProcesses) {
        terminal.exit(0);
      }
      await harness.dispose();
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    test('terminal create is guarded, jailed, sanitized, and output-capped before spawn', () async {
      acpProcess.sendHostRequest(100, 'terminal/create', {
        'command': 'echo hello',
        'cwd': '.',
        'env': {'ANTHROPIC_API_KEY': 'secret', 'OPENAI_API_KEY': 'secret', 'PATH': '/custom/bin'},
        'outputByteLimit': 99,
      });
      final response = await acpProcess.waitForResponse(100);

      expect(response['result'], containsPair('terminalId', 'terminal-1'));
      expect(response['result'], containsPair('outputByteLimit', 8));
      expect(guard.lastContext!.toolName, 'shell');
      expect(guard.lastContext!.rawProviderToolName, 'terminal/create');
      expect(terminalProcesses, hasLength(1));
      expect(capturedWorkingDirectories.single, workspace.resolveSymbolicLinksSync());
      expect(capturedEnvironments.single, isNot(contains('ANTHROPIC_API_KEY')));
      expect(capturedEnvironments.single, isNot(contains('OPENAI_API_KEY')));
      expect(capturedEnvironments.single, containsPair('PATH', '/custom/bin'));
    });

    test('blocked terminal create does not spawn', () async {
      await harness.dispose();
      guard = RecordingGuard(verdict: GuardVerdict.block('blocked command'));
      acpProcess = FakeAcpProcess();
      terminalProcesses = [];
      harness = _harness(
        workspace: workspace,
        acpProcess: acpProcess,
        guard: guard,
        auditEvents: auditEvents,
        terminalProcesses: terminalProcesses,
        capturedEnvironments: capturedEnvironments,
        capturedWorkingDirectories: capturedWorkingDirectories,
      );
      final startFuture = harness.start();
      await acpProcess.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      acpProcess.sendHostRequest(101, 'terminal/create', {'command': 'rm -rf .'});
      final response = await acpProcess.waitForResponse(101);

      expect(response['result'], containsPair('noAccess', true));
      expect(terminalProcesses, isEmpty);
    });

    test('terminal lifecycle is limited to host-created IDs and does not re-enter shell guard', () async {
      acpProcess.sendHostRequest(200, 'terminal/create', {'command': 'echo hello', 'outputByteLimit': 4});
      await acpProcess.waitForResponse(200);
      final terminal = terminalProcesses.single;
      terminal.emitStdout('abcdef');

      acpProcess.sendHostRequest(201, 'terminal/output', {'terminalId': 'terminal-1'});
      final output = await acpProcess.waitForResponse(201);

      expect(output['result'], containsPair('output', 'abcd'));
      expect(output['result'], containsPair('truncated', true));

      acpProcess.sendHostRequest(202, 'terminal/wait_for_exit', {'terminalId': 'terminal-1'});
      terminal.exit(7);
      final wait = await acpProcess.waitForResponse(202);
      expect(wait['result'], containsPair('exitCode', 7));

      acpProcess.sendHostRequest(203, 'terminal/kill', {'terminalId': 'terminal-1'});
      final kill = await acpProcess.waitForResponse(203);
      expect(kill['result'], containsPair('ok', true));

      acpProcess.sendHostRequest(204, 'terminal/release', {'terminalId': 'terminal-1'});
      await acpProcess.waitForResponse(204);
      acpProcess.sendHostRequest(205, 'terminal/output', {'terminalId': 'terminal-1'});
      final released = await acpProcess.waitForResponse(205);

      expect(released['error'], isNotNull);
      expect(guard.contexts, hasLength(1));
      expect(terminalProcesses, hasLength(1));
      expect(
        auditEvents.map((event) => event.rawProviderToolName),
        containsAll(['terminal/output', 'terminal/release']),
      );
    });

    test('outputByteLimit caps bytes, not decoded string length', () async {
      acpProcess.sendHostRequest(300, 'terminal/create', {'command': 'echo hello', 'outputByteLimit': 4});
      await acpProcess.waitForResponse(300);
      terminalProcesses.single.emitStdout('ååå');

      acpProcess.sendHostRequest(301, 'terminal/output', {'terminalId': 'terminal-1'});
      final output = await acpProcess.waitForResponse(301);

      expect(output['result'], containsPair('output', 'åå'));
      expect(output['result'], containsPair('truncated', true));
    });

    test('terminal release waits for a live host-created process to exit', () async {
      acpProcess.sendHostRequest(350, 'terminal/create', {'command': 'sleep 60'});
      await acpProcess.waitForResponse(350);
      final terminal = terminalProcesses.single;

      acpProcess.sendHostRequest(351, 'terminal/release', {'terminalId': 'terminal-1'});
      await pumpEventQueue();
      expect(terminal.killCalled, isTrue);
      expect(acpProcess.capturedStdinJson.where((message) => message['id'] == 351), isEmpty);

      terminal.exit(0);
      final release = await acpProcess.waitForResponse(351);

      expect(release['result'], containsPair('ok', true));
      expect(terminal.killCalled, isTrue);
    });

    test('unconfirmed terminal release reports failure, warns, and retains ownership', () {
      fakeAsync((async) {
        final process = CapturingFakeProcess();
        final handlers = AcpReverseCallHandlers(
          cwd: workspace.path,
          terminalProcessFactory:
              (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                  process,
        );
        final warnings = <LogRecord>[];
        final subscription = Logger(
          'AcpReverseCallHandlers',
        ).onRecord.where((record) => record.level >= Level.WARNING).listen(warnings.add);
        Map<String, dynamic>? release;
        Map<String, dynamic>? retained;

        unawaited(
          handlers
              .createTerminal({'command': 'sleep 60'})
              .then((_) => handlers.releaseTerminal({'terminalId': 'terminal-1'}))
              .then((value) async {
                release = value;
                retained = await handlers.terminalOutput({'terminalId': 'terminal-1'});
              }),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        expect(release, containsPair('ok', false));
        expect(warnings, isNotEmpty);
        expect(warnings.last.message, allOf(contains('ACP terminal-1'), contains('could not be confirmed')));
        expect(retained, containsPair('output', ''), reason: 'an unconfirmed process remains owned for later cleanup');

        final firstAttemptSignals = process.killSignals.length;
        Map<String, dynamic>? retry;
        Object? lookupError;
        unawaited(
          handlers
              .releaseTerminal({'terminalId': 'terminal-1'})
              .then((value) {
                retry = value;
                return handlers.terminalOutput({'terminalId': 'terminal-1'});
              })
              .then<void>((_) {}, onError: (Object error, StackTrace _) => lookupError = error),
        );
        async.flushMicrotasks();
        expect(process.killSignals.length, greaterThan(firstAttemptSignals));

        process.exit(0);
        async.flushMicrotasks();

        expect(retry, containsPair('ok', true));
        expect('$lookupError', contains('Unknown ACP terminal'));
        unawaited(subscription.cancel());
      });
    });

    test('terminal disposal starts every termination within one grace window', () {
      fakeAsync((async) {
        final processes = List.generate(3, (_) => CapturingFakeProcess());
        var nextProcess = 0;
        final handlers = AcpReverseCallHandlers(
          cwd: workspace.path,
          terminalProcessFactory:
              (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                  processes[nextProcess++],
        );
        var disposed = false;

        unawaited(
          Future.wait(
            List.generate(3, (_) => handlers.createTerminal({'command': 'sleep 60'})),
          ).then((_) => handlers.disposeTerminals()).then((_) => disposed = true),
        );
        async.flushMicrotasks();

        expect(processes.every((process) => process.killCalled), isTrue);
        expect(disposed, isFalse);

        for (final process in processes) {
          process.exit(0);
        }
        async.flushMicrotasks();

        expect(disposed, isTrue);
      });
    });

    test('overlapping release and disposal share one termination attempt', () {
      fakeAsync((async) {
        final process = CapturingFakeProcess();
        final handlers = AcpReverseCallHandlers(
          cwd: workspace.path,
          terminalProcessFactory:
              (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                  process,
        );
        Map<String, dynamic>? release;
        var disposed = false;

        unawaited(
          handlers.createTerminal({'command': 'sleep 60'}).then((_) {
            unawaited(handlers.releaseTerminal({'terminalId': 'terminal-1'}).then((value) => release = value));
            unawaited(handlers.disposeTerminals().then((_) => disposed = true));
          }),
        );
        async.flushMicrotasks();

        expect(process.killSignals, [ProcessSignal.sigterm]);
        expect(disposed, isFalse);
        expect(release, isNull);

        process.exit(0);
        async.flushMicrotasks();

        expect(release, containsPair('ok', true));
        expect(disposed, isTrue);
        expect(process.killSignals, [ProcessSignal.sigterm]);
      });
    });

    test('stop waits for host-created terminal processes to exit', () async {
      acpProcess.sendHostRequest(400, 'terminal/create', {'command': 'sleep 60'});
      await acpProcess.waitForResponse(400);
      final terminal = terminalProcesses.single;
      var stopped = false;

      final stopFuture = harness.stop().then((_) => stopped = true);
      await pumpEventQueue();
      expect(terminal.killCalled, isTrue);
      expect(stopped, isFalse);

      terminal.exit(0);
      await stopFuture;

      expect(terminal.killCalled, isTrue);
      expect(stopped, isTrue);
    });
  });
}

AcpHarness _harness({
  required Directory workspace,
  required FakeAcpProcess acpProcess,
  required RecordingGuard guard,
  required List<AcpReverseCallAuditEvent> auditEvents,
  required List<CapturingFakeProcess> terminalProcesses,
  required List<Map<String, String>?> capturedEnvironments,
  required List<String?> capturedWorkingDirectories,
}) {
  return AcpHarness(
    cwd: workspace.path,
    executable: 'goose',
    arguments: const ['acp'],
    guardChain: GuardChain(guards: [guard]),
    onReverseCallAudit: auditEvents.add,
    terminalOutputByteLimit: 8,
    environment: const {'PATH': '/usr/bin', 'ANTHROPIC_API_KEY': 'parent-secret'},
    processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
        acpProcess,
    terminalProcessFactory:
        (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
          final terminal = CapturingFakeProcess();
          terminalProcesses.add(terminal);
          capturedEnvironments.add(environment);
          capturedWorkingDirectories.add(workingDirectory);
          return terminal;
        },
  );
}
