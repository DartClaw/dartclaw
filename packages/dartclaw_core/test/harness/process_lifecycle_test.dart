import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_core/dartclaw_core.dart' show ProcessTerminationResult, killWithEscalation;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('killWithEscalation', () {
    test('Windows semantics use one hard termination without POSIX escalation', () {
      fakeAsync((async) {
        final process = FakeProcess();
        ProcessTerminationResult? result;
        final terminatedPids = <int>[];

        unawaited(
          killWithEscalation(
            process,
            label: 'windows-child',
            gracePeriod: const Duration(seconds: 5),
            platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
            windowsProcessTreeTerminator: (pid) async {
              terminatedPids.add(pid);
              return true;
            },
          ).then((value) => result = value),
        );
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(terminatedPids, [process.pid]);
        expect(process.killSignals, isEmpty);
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();

        expect(process.killSignals, isEmpty);
        expect(result?.initialTerminationAccepted, isTrue);
        expect(result?.exitConfirmed, isFalse);
        expect(result?.hardTerminationUsed, isTrue);
        expect(result?.processTreeTerminationAccepted, isTrue);
        expect(result?.confirmsOwnershipRelease(), isFalse);
      });
    });

    test('Windows semantics skip tree termination when the managed root already exited', () async {
      final process = FakeProcess()..exit(0);
      var terminationCalls = 0;

      final result = await killWithEscalation(
        process,
        label: 'already-exited-child',
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        windowsProcessTreeTerminator: (_) async {
          terminationCalls++;
          return true;
        },
      );

      expect(terminationCalls, isZero);
      expect(process.killSignals, isEmpty);
      expect(result.initialTerminationAccepted, isFalse);
      expect(result.exitConfirmed, isTrue);
      expect(result.hardTerminationUsed, isFalse);
      expect(result.processTreeTerminationAccepted, isFalse);
      expect(result.confirmsOwnershipRelease(), isTrue);
    });

    test('Windows tree termination is bounded when an injected terminator never completes', () {
      fakeAsync((async) {
        final process = FakeProcess(completeExitOnKill: true);
        final neverCompletes = Completer<bool>();
        ProcessTerminationResult? result;

        unawaited(
          killWithEscalation(
            process,
            label: 'hung-tree-terminator',
            gracePeriod: const Duration(seconds: 5),
            platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
            windowsProcessTreeTerminator: (_) => neverCompletes.future,
          ).then((value) => result = value),
        );
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(result, isNull);
        expect(process.killSignals, isEmpty);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(process.killSignals, [ProcessSignal.sigterm]);
        expect(result?.initialTerminationAccepted, isFalse);
        expect(result?.exitConfirmed, isTrue);
        expect(result?.hardTerminationUsed, isTrue);
        expect(result?.processTreeTerminationAccepted, isFalse);
        expect(result?.confirmsOwnershipRelease(), isTrue);
      });
    });

    test('default Windows termination kills only the managed root and fails closed for tree ownership', () async {
      final process = FakeProcess(completeExitOnKill: true);

      final result = await killWithEscalation(
        process,
        label: 'windows-root',
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
      );

      expect(process.killSignals, [ProcessSignal.sigterm]);
      expect(result.initialTerminationAccepted, isTrue);
      expect(result.exitConfirmed, isTrue);
      expect(result.processTreeTerminationAccepted, isFalse);
      expect(result.confirmsOwnershipRelease(), isTrue);
    });

    test('ownership-safe Windows tree termination can confirm release', () async {
      final process = FakeProcess();

      final result = await killWithEscalation(
        process,
        label: 'owned-windows-tree',
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        windowsProcessTreeTerminator: (_) async {
          process.exit(0);
          return true;
        },
      );

      expect(process.killSignals, isEmpty);
      expect(result.exitConfirmed, isTrue);
      expect(result.processTreeTerminationAccepted, isTrue);
      expect(result.confirmsOwnershipRelease(), isTrue);
    });

    test('POSIX semantics escalate to SIGKILL and confirm the exit', () {
      fakeAsync((async) {
        final process = FakeProcess();
        ProcessTerminationResult? result;

        unawaited(
          killWithEscalation(
            process,
            label: 'posix-child',
            gracePeriod: const Duration(seconds: 5),
            platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
          ).then((value) => result = value),
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(process.killSignals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);

        process.exit(-9);
        async.flushMicrotasks();

        expect(result?.initialTerminationAccepted, isTrue);
        expect(result?.exitConfirmed, isTrue);
        expect(result?.hardTerminationUsed, isTrue);
        expect(result?.processTreeTerminationAccepted, isFalse);
        expect(result?.confirmsOwnershipRelease(), isTrue);
      });
    });

    test('an exit observed within the grace period is confirmed', () {
      fakeAsync((async) {
        final process = FakeProcess();
        ProcessTerminationResult? result;

        unawaited(
          killWithEscalation(
            process,
            label: 'prompt-child',
            gracePeriod: const Duration(seconds: 5),
            platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
          ).then((value) => result = value),
        );
        async.flushMicrotasks();
        process.exit(0);
        async.flushMicrotasks();

        expect(result?.exitConfirmed, isTrue);
        expect(result?.hardTerminationUsed, isFalse);
        expect(process.killSignals, [ProcessSignal.sigterm]);
      });
    });

    test('a rejected earlier termination request is reported honestly without a duplicate request', () {
      fakeAsync((async) {
        final process = FakeProcess();
        ProcessTerminationResult? result;

        unawaited(
          killWithEscalation(
            process,
            label: 'rejected-child',
            gracePeriod: const Duration(seconds: 5),
            initialTerminationAccepted: false,
            platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
            windowsProcessTreeTerminator: (_) async => true,
          ).then((value) => result = value),
        );
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(process.killSignals, isEmpty);
        expect(result?.initialTerminationAccepted, isFalse);
        expect(result?.exitConfirmed, isFalse);
      });
    });

    test('unconfirmed Windows termination logs a platform-honest warning', () {
      fakeAsync((async) {
        final process = FakeProcess();
        final logger = Logger('process-lifecycle-windows-test');
        final warnings = <String>[];
        final subscription = logger.onRecord
            .where((record) => record.level >= Level.WARNING)
            .listen((record) => warnings.add(record.message));
        ProcessTerminationResult? result;

        unawaited(
          killWithEscalation(
            process,
            label: 'stuck-child',
            gracePeriod: const Duration(seconds: 5),
            log: logger,
            platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
            windowsProcessTreeTerminator: (_) async => true,
          ).then((value) => result = value),
        );
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();

        expect(result?.exitConfirmed, isFalse);
        expect(warnings, hasLength(1));
        expect(warnings.single, contains('stuck-child'));
        expect(warnings.single, contains('hard termination could not be confirmed'));
        expect(warnings.single, isNot(anyOf(contains('SIGTERM'), contains('SIGKILL'))));
        unawaited(subscription.cancel());
      });
    });

    test('unconfirmed POSIX termination names the escalation path', () {
      fakeAsync((async) {
        final process = FakeProcess();
        final logger = Logger('process-lifecycle-posix-test');
        final warnings = <String>[];
        final subscription = logger.onRecord
            .where((record) => record.level >= Level.WARNING)
            .listen((record) => warnings.add(record.message));

        unawaited(
          killWithEscalation(
            process,
            label: 'stuck-child',
            gracePeriod: const Duration(seconds: 5),
            log: logger,
            platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
          ),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();

        expect(warnings.last, allOf(contains('stuck-child'), contains('SIGTERM-to-SIGKILL escalation')));
        unawaited(subscription.cancel());
      });
    });
  });

  test(
    'native Windows shutdown fails closed without an ownership-safe tree terminator',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp('dartclaw-process-lifecycle-');
      final script = File('${tempDirectory.path}${Platform.pathSeparator}managed_child.dart');
      await script.writeAsString(
        "import 'dart:async';\n"
        "import 'dart:io';\n"
        'Future<void> main(List<String> args) async {\n'
        "  if (args.contains('child')) {\n"
        '    Timer.periodic(const Duration(days: 1), (_) {});\n'
        '    return;\n'
        '  }\n'
        "  final child = await Process.start(Platform.resolvedExecutable, [Platform.script.toFilePath(), 'child']);\n"
        '  stdout.writeln(child.pid);\n'
        '  await stdout.flush();\n'
        '  Timer.periodic(const Duration(days: 1), (_) {});\n'
        '}\n',
      );
      final process = await Process.start(Platform.resolvedExecutable, [script.path]);
      final childPid = int.parse(await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).first);

      try {
        final result = await killWithEscalation(process, label: 'native-Windows managed child');
        expect(result.exitConfirmed, isTrue, reason: 'the managed root process must be reaped');
        expect(result.hardTerminationUsed, isTrue);
        expect(result.processTreeTerminationAccepted, isFalse);
        expect(result.confirmsOwnershipRelease(), isTrue);
        print('Native Windows process lifecycle: directly managed root PID ${process.pid} reaped.');
      } finally {
        process.kill();
        Process.killPid(childPid);
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // The test assertion reports the unreaped process; cleanup stays bounded.
        }
        await tempDirectory.delete(recursive: true);
      }
    },
    skip: PlatformCapabilities().posixSignalsAvailable ? 'Native Windows lifecycle evidence' : false,
  );
}
