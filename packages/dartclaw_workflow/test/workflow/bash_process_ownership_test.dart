import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:dartclaw_workflow/src/workflow/bash_process_owner.dart';
import 'package:dartclaw_workflow/src/workflow/bash_step_runner.dart';
import 'package:test/test.dart';

void main() {
  group('Bash process ownership', () {
    test('an already-exited Windows root retains ownership without tree-cleanup proof', () async {
      final process = FakeProcess()..exit(0);
      final owner = BashProcessOwner()
        ..track(process)
        ..markCleanupPending(process);
      var terminationCalls = 0;

      final exitConfirmed = await owner.runCleanupAttempt(
        process,
        () => terminateBashProcessTree(
          process,
          PlatformCapabilities(operatingSystem: 'windows'),
          rootProcessIdentity: null,
          windowsTreeTerminator: (_) async {
            terminationCalls++;
            return ProcessResult(0, 0, '', '');
          },
          onWindowsTreeCleanupStateChanged: (unconfirmed) =>
              owner.setWindowsTreeCleanupUnconfirmed(process, unconfirmed: unconfirmed),
        ),
      );

      expect(exitConfirmed, isFalse);
      expect(terminationCalls, isZero);
      expect(owner.owns(process), isTrue);
      expect(owner.windowsTreeCleanupUnconfirmed(process), isTrue);
    });

    test('failed Windows tree cleanup remains unconfirmed after the root exits', () async {
      final process = FakeProcess(completeExitOnKill: true);
      final owner = BashProcessOwner()
        ..track(process)
        ..markCleanupPending(process);
      final capabilities = PlatformCapabilities(operatingSystem: 'windows');
      var terminationCalls = 0;

      final firstExitConfirmed = await owner.runCleanupAttempt(
        process,
        () => terminateBashProcessTree(
          process,
          capabilities,
          rootProcessIdentity: null,
          gracePeriod: Duration.zero,
          windowsTreeTerminator: (_) async {
            terminationCalls++;
            return ProcessResult(0, 1, '', 'failed');
          },
          onWindowsTreeCleanupStateChanged: (unconfirmed) =>
              owner.setWindowsTreeCleanupUnconfirmed(process, unconfirmed: unconfirmed),
        ),
      );

      expect(firstExitConfirmed, isFalse);
      expect(owner.windowsTreeCleanupUnconfirmed(process), isTrue);
      expect(process.killCalled, isTrue);

      await retryOwnedBashProcesses(
        owner,
        capabilities,
        gracePeriod: Duration.zero,
        windowsTreeTerminator: (_) async {
          terminationCalls++;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(terminationCalls, 1, reason: 'an exited root PID cannot be targeted safely on retry');
      expect(owner.owns(process), isTrue);
      expect(owner.cleanupPendingProcesses, contains(process));
      expect(owner.windowsTreeCleanupUnconfirmed(process), isTrue);
    });

    test('accepted Windows root termination does not masquerade as tree proof', () async {
      final process = FakeProcess(completeExitOnKill: true);
      final owner = BashProcessOwner()
        ..track(process)
        ..markCleanupPending(process);
      final capabilities = PlatformCapabilities(operatingSystem: 'windows');

      final confirmed = await owner.runCleanupAttempt(
        process,
        () => terminateBashProcessTree(
          process,
          capabilities,
          rootProcessIdentity: null,
          gracePeriod: Duration.zero,
          onWindowsTreeCleanupStateChanged: (unconfirmed) =>
              owner.setWindowsTreeCleanupUnconfirmed(process, unconfirmed: unconfirmed),
        ),
      );

      expect(confirmed, isFalse);
      expect(owner.windowsTreeCleanupUnconfirmed(process), isTrue);

      await retryOwnedBashProcesses(owner, capabilities, gracePeriod: Duration.zero);

      expect(owner.owns(process), isTrue);
      expect(owner.cleanupPendingProcesses, contains(process));
    });

    test('POSIX discovery rejects children when the captured root PID was reused', () async {
      final process = FakeProcess(pid: 500, completeExitOnKill: true);
      var childLookupCalls = 0;

      final exitConfirmed = await terminateBashProcessTree(
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        rootProcessIdentity: 'original-root',
        gracePeriod: Duration.zero,
        posixProcessIdentityLookup: (_) async => null,
        posixProcessSnapshotLookup: (_) async => (identity: 'reused-root', parentPid: 1),
        posixChildPidLookup: (_) async {
          childLookupCalls++;
          return const [101];
        },
        posixProcessSignaler: (_, _) => true,
      );

      expect(exitConfirmed, isTrue);
      expect(childLookupCalls, isZero);
    });

    test('POSIX root exit cannot release descendant ownership without a spawn identity', () async {
      final process = FakeProcess(completeExitOnKill: true);

      final confirmed = await terminateBashProcessTree(
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        rootProcessIdentity: null,
        gracePeriod: Duration.zero,
        posixProcessIdentityLookup: (_) async => null,
        posixProcessSnapshotLookup: (_) async => null,
        posixChildPidLookup: (_) async => const [],
        posixProcessSignaler: (_, _) => true,
      );

      expect(process.killCalled, isTrue);
      expect(confirmed, isFalse);
    });

    test('POSIX child-enumeration failure retains ownership', () async {
      final process = FakeProcess(completeExitOnKill: true);

      final confirmed = await terminateBashProcessTree(
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        rootProcessIdentity: 'root-start',
        gracePeriod: Duration.zero,
        posixProcessSnapshotLookup: (_) async => (identity: 'root-start', parentPid: 1),
        posixChildPidLookup: (_) async => throw const PosixProcessInspectionException('enumeration failed'),
        posixProcessSignaler: (_, _) => true,
      );

      expect(process.killCalled, isTrue);
      expect(confirmed, isFalse);
    });

    test('POSIX survivor-probe failure retains ownership', () async {
      const childPid = 101;
      final process = FakeProcess()..exit(0);

      final confirmed = await terminateBashProcessTree(
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        rootProcessIdentity: 'root-start',
        knownDescendantIdentities: const {childPid: 'child-start'},
        rootExitAlreadyObserved: true,
        gracePeriod: Duration.zero,
        posixProcessIdentityLookup: (_) async => throw const PosixProcessInspectionException('probe failed'),
        posixProcessSnapshotLookup: (_) async => null,
        posixChildPidLookup: (_) async => const [],
        posixProcessSignaler: (_, _) => true,
      );

      expect(confirmed, isFalse);
    });

    test('POSIX discovery revalidates an intermediate parent before enumerating its children', () async {
      const childPid = 101;
      final process = FakeProcess(pid: 500, completeExitOnKill: true);
      var childSnapshotReads = 0;
      var intermediateLookupCalls = 0;
      final signals = <(int, ProcessSignal)>[];

      final exitConfirmed = await terminateBashProcessTree(
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        rootProcessIdentity: 'root-start',
        gracePeriod: Duration.zero,
        posixProcessIdentityLookup: (pid) async => pid == childPid ? 'reused-child' : null,
        posixProcessSnapshotLookup: (pid) async {
          if (pid == process.pid) return (identity: 'root-start', parentPid: 1);
          if (pid == childPid) {
            childSnapshotReads++;
            return (identity: childSnapshotReads == 1 ? 'owned-child' : 'reused-child', parentPid: process.pid);
          }
          return (identity: 'unrelated-grandchild', parentPid: childPid);
        },
        posixChildPidLookup: (parentPid) async {
          if (parentPid == process.pid) return const [childPid];
          intermediateLookupCalls++;
          return const [202];
        },
        posixProcessSignaler: (pid, signal) {
          signals.add((pid, signal));
          return true;
        },
      );

      expect(exitConfirmed, isTrue);
      expect(intermediateLookupCalls, isZero);
      expect(signals, isEmpty);
    });

    test('descendant watcher retains identities captured before root exit', () async {
      const childPid = 101;
      final process = FakeProcess(pid: 500);
      final owner = BashProcessOwner()
        ..track(process)
        ..setRootIdentity(process, 'root-start');

      await trackOwnedBashDescendants(
        owner,
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        interval: Duration.zero,
        posixProcessSnapshotLookup: (pid) async => switch (pid) {
          500 => (identity: 'root-start', parentPid: 1),
          childPid => (identity: 'child-start', parentPid: 500),
          _ => null,
        },
        posixChildPidLookup: (pid) async {
          if (pid == process.pid) {
            process.exit(0);
            return const [childPid];
          }
          return const [];
        },
      );

      expect(owner.descendantIdentitiesOf(process), {childPid: 'child-start'});
    });

    test('unidentified descendants retain ownership and are not retargeted by PID', () async {
      final process = FakeProcess()..exit(0);
      final owner = BashProcessOwner()
        ..track(process)
        ..markCleanupPending(process)
        ..markUnidentifiedDescendantCleanup(process);
      var terminationCalls = 0;

      await retryOwnedBashProcesses(
        owner,
        PlatformCapabilities(operatingSystem: 'windows'),
        gracePeriod: Duration.zero,
        windowsTreeTerminator: (_) async {
          terminationCalls++;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(terminationCalls, isZero);
      expect(owner.owns(process), isTrue);
      expect(owner.cleanupPendingProcesses, contains(process));
    });

    test('timeout cleanup terminates a descendant captured while the root exits', () async {
      const childPid = 101;
      final process = FakeProcess(pid: 500, completeExitOnKill: true);
      final owner = BashProcessOwner()
        ..track(process)
        ..setRootIdentity(process, 'root-start')
        ..markCleanupPending(process);
      final liveIdentities = <int, String>{childPid: 'child-start'};
      final signals = <(int, ProcessSignal)>[];
      final descendantTracking = process.exitCode.then<Map<int, String>>((_) => const {childPid: 'child-start'});

      final confirmed = await cleanupTimedOutBashProcess(
        owner,
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        descendantTracking: descendantTracking,
        rootExitAlreadyObserved: false,
        gracePeriod: Duration.zero,
        posixProcessIdentityLookup: (pid) async => liveIdentities[pid],
        posixProcessSnapshotLookup: (pid) async => pid == process.pid
            ? (identity: 'root-start', parentPid: 1)
            : (identity: liveIdentities[pid]!, parentPid: process.pid),
        posixChildPidLookup: (_) async => const [],
        posixProcessSignaler: (pid, signal) {
          signals.add((pid, signal));
          liveIdentities.remove(pid);
          return true;
        },
      );

      expect(confirmed, isTrue);
      expect(signals, [(childPid, ProcessSignal.sigterm)]);
      expect(owner.descendantIdentitiesOf(process), isEmpty);
    });

    test('cleanup remains coalesced until inherited-output proof completes', () async {
      final process = FakeProcess()..exit(0);
      final owner = BashProcessOwner()
        ..track(process)
        ..setRootIdentity(process, 'root-start')
        ..markCleanupPending(process);
      final proofStarted = Completer<void>();
      final proof = Completer<bool>();

      final cleanup = cleanupTimedOutBashProcess(
        owner,
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        descendantTracking: Future.value(const <int, String>{}),
        rootExitAlreadyObserved: true,
        gracePeriod: Duration.zero,
        confirmDescendantOutputsClosed: () {
          proofStarted.complete();
          return proof.future;
        },
      );
      await proofStarted.future;
      final retry = retryOwnedBashProcesses(
        owner,
        PlatformCapabilities(operatingSystem: 'linux'),
        gracePeriod: Duration.zero,
      );

      expect(owner.owns(process), isTrue);
      proof.complete(false);

      expect(await cleanup, isFalse);
      await retry;
      expect(owner.owns(process), isTrue);
      expect(owner.unidentifiedDescendantCleanup(process), isTrue);
    });

    test('unconfirmed root termination does not wait forever for descendant tracking', () async {
      final process = FakeProcess();
      final owner = BashProcessOwner()
        ..track(process)
        ..markCleanupPending(process);
      final tracking = Completer<Map<int, String>>();

      final confirmed = await cleanupTimedOutBashProcess(
        owner,
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        descendantTracking: tracking.future,
        rootExitAlreadyObserved: false,
        gracePeriod: Duration.zero,
      ).timeout(const Duration(seconds: 1));

      expect(confirmed, isFalse);
      expect(owner.owns(process), isTrue);
    });

    test('tracker inspection failure prevents timeout cleanup release', () async {
      final process = FakeProcess()..exit(0);
      final owner = BashProcessOwner()
        ..track(process)
        ..setRootIdentity(process, 'root-start')
        ..markCleanupPending(process);
      final tracking = Future<Map<int, String>>.sync(() {
        owner.markUnidentifiedDescendantCleanup(process);
        return const <int, String>{};
      });

      final confirmed = await cleanupTimedOutBashProcess(
        owner,
        process,
        PlatformCapabilities(operatingSystem: 'linux'),
        descendantTracking: tracking,
        rootExitAlreadyObserved: true,
        gracePeriod: Duration.zero,
      );

      expect(confirmed, isFalse);
      expect(owner.owns(process), isTrue);
      expect(owner.unidentifiedDescendantCleanup(process), isTrue);
    });
  });
}
