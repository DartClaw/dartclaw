import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

/// Creates a ContainerManager with a custom `docker inspect` response.
ContainerManager _makeManager({required String profileId, required bool Function() isRunning}) {
  return ContainerManager(
    config: ContainerConfig(enabled: true, image: 'test:latest'),
    containerName: 'test-$profileId',
    profileId: profileId,
    workspaceMounts: [],
    generatedStateDir: '/tmp/dartclaw-state-$profileId',
    bridgeBinaryPath: '/tmp/dartclaw-bridge',
    runCommand: (executable, arguments) async {
      // Respond to `docker inspect --format {{.State.Running}} <name>`.
      // A crashed container is stopped-but-present (exit 0, "false") — an
      // unambiguous not-running that never conflates with a daemon error.
      if (arguments.contains('inspect')) {
        return ProcessResult(0, 0, isRunning() ? 'true\n' : 'false\n', '');
      }
      return ProcessResult(0, 0, '', '');
    },
  );
}

void main() {
  group('ContainerHealthMonitor', () {
    test('fires ContainerCrashedEvent on healthy-to-unhealthy transition', () async {
      var healthy = true;
      final manager = _makeManager(profileId: 'workspace', isRunning: () => healthy);
      final eventBus = EventBus();
      final events = <DartclawEvent>[];
      eventBus.on<ContainerCrashedEvent>().listen(events.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager);

      // Let it settle with healthy state
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(events, isEmpty);

      // Simulate crash
      healthy = false;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await monitor.stop();

      expect(events, hasLength(1));
      expect(events.first, isA<ContainerCrashedEvent>());
      final event = events.first as ContainerCrashedEvent;
      expect(event.profileId, 'workspace');
      expect(event.containerName, 'test-workspace');

      await eventBus.dispose();
    });

    test('fires ContainerStartedEvent on unhealthy-to-healthy transition', () async {
      var healthy = false;
      final manager = _makeManager(profileId: 'restricted', isRunning: () => healthy);
      final eventBus = EventBus();
      final crashEvents = <ContainerCrashedEvent>[];
      final startEvents = <ContainerStartedEvent>[];
      eventBus.on<ContainerCrashedEvent>().listen(crashEvents.add);
      eventBus.on<ContainerStartedEvent>().listen(startEvents.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager);

      // First poll detects healthy→unhealthy (initial state is assumed healthy)
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(crashEvents, hasLength(1));

      // Recover
      healthy = true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await monitor.stop();

      expect(startEvents, hasLength(1));
      expect(startEvents.first.profileId, 'restricted');

      await eventBus.dispose();
    });

    test('does not fire events when health stays stable', () async {
      final manager = _makeManager(profileId: 'workspace', isRunning: () => true);
      final eventBus = EventBus();
      final events = <DartclawEvent>[];
      eventBus.on<ContainerLifecycleEvent>().listen(events.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await monitor.stop();

      expect(events, isEmpty);

      await eventBus.dispose();
    });

    test('an unwatched container produces no crash event when it is torn down', () async {
      var healthy = true;
      final manager = _makeManager(profileId: 'workspace', isRunning: () => healthy);
      final eventBus = EventBus();
      final events = <ContainerCrashedEvent>[];
      eventBus.on<ContainerCrashedEvent>().listen(events.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Release deregisters before teardown, so the container disappearing is
      // a normal release rather than a crash.
      monitor.unwatch(manager.containerName);
      healthy = false;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await monitor.stop();

      expect(events, isEmpty);
      expect(monitor.watchedContainers, isEmpty);

      await eventBus.dispose();
    });

    test('watches concurrent authorities of the same profile independently', () async {
      var firstHealthy = true;
      final first = _makeManager(profileId: 'workspace', isRunning: () => firstHealthy);
      final second = ContainerManager(
        config: ContainerConfig(enabled: true, image: 'test:latest'),
        containerName: 'test-workspace-2',
        profileId: 'workspace',
        workspaceMounts: [],
        generatedStateDir: '/tmp/dartclaw-state-workspace-2',
        runCommand: (executable, arguments) async => ProcessResult(0, 0, 'true\n', ''),
      );
      final eventBus = EventBus();
      final events = <ContainerCrashedEvent>[];
      eventBus.on<ContainerCrashedEvent>().listen(events.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(first.containerName, first)
        ..watch(second.containerName, second);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      firstHealthy = false;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await monitor.stop();

      expect(events.map((e) => e.containerName), ['test-workspace']);

      await eventBus.dispose();
    });

    test('a crash names the execution the authority was leased for', () async {
      var healthy = true;
      final manager = _makeManager(profileId: 'restricted', isRunning: () => healthy);
      final eventBus = EventBus();
      final events = <ContainerCrashedEvent>[];
      eventBus.on<ContainerCrashedEvent>().listen(events.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager, taskId: 'restricted-task-a');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      healthy = false;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await monitor.stop();

      // Attribution travels with the event: without it the subscriber can only
      // guess from the profile and fails every task that shares it.
      expect(events.single.taskId, 'restricted-task-a');

      await eventBus.dispose();
    });

    test('a daemon-connection inspect error is not a crash', () async {
      // exit 1 with a daemon-connection stderr — indistinguishable from a dead
      // container by exit code alone, but it proves nothing, so no crash fires.
      final manager = ContainerManager(
        config: ContainerConfig(enabled: true, image: 'test:latest'),
        containerName: 'test-daemon-blip',
        profileId: 'workspace',
        workspaceMounts: [],
        generatedStateDir: '/tmp/dartclaw-state-daemon-blip',
        runCommand: (executable, arguments) async => arguments.contains('inspect')
            ? ProcessResult(0, 1, '', 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock.')
            : ProcessResult(0, 0, '', ''),
      );
      final eventBus = EventBus();
      final events = <ContainerCrashedEvent>[];
      eventBus.on<ContainerCrashedEvent>().listen(events.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager, taskId: 'task-a');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await monitor.stop();

      expect(events, isEmpty);

      await eventBus.dispose();
    });

    test('a removed container (no such object) still fires a crash', () async {
      var removed = false;
      final manager = ContainerManager(
        config: ContainerConfig(enabled: true, image: 'test:latest'),
        containerName: 'test-removed',
        profileId: 'workspace',
        workspaceMounts: [],
        generatedStateDir: '/tmp/dartclaw-state-removed',
        runCommand: (executable, arguments) async {
          if (!arguments.contains('inspect')) return ProcessResult(0, 0, '', '');
          return removed
              ? ProcessResult(0, 1, '', 'Error: No such object: test-removed')
              : ProcessResult(0, 0, 'true\n', '');
        },
      );
      final eventBus = EventBus();
      final events = <ContainerCrashedEvent>[];
      eventBus.on<ContainerCrashedEvent>().listen(events.add);

      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager, taskId: 'task-b');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(events, isEmpty);

      removed = true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await monitor.stop();

      expect(events.single.taskId, 'task-b');

      await eventBus.dispose();
    });

    test('slow health checks stay single-flight across timer ticks and timeouts', () async {
      final inspectResult = Completer<ProcessResult>();
      var inspectCalls = 0;
      final manager = ContainerManager(
        config: const ContainerConfig(enabled: true, image: 'test:latest'),
        containerName: 'test-slow-health',
        profileId: 'workspace',
        workspaceMounts: const [],
        generatedStateDir: '/tmp/dartclaw-state-slow-health',
        runCommand: (executable, arguments) async {
          if (!arguments.contains('inspect')) return ProcessResult(0, 0, '', '');
          inspectCalls++;
          return inspectResult.future;
        },
      );
      final eventBus = EventBus();
      final monitor =
          ContainerHealthMonitor(
              eventBus: eventBus,
              interval: const Duration(milliseconds: 5),
              healthCheckTimeout: const Duration(milliseconds: 15),
            )
            ..watch(manager.containerName, manager)
            ..start();

      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(inspectCalls, 1, reason: 'a timed-out Docker inspect must not overlap a later poll');

      await monitor.stop();
      inspectResult.complete(ProcessResult(0, 0, 'true\n', ''));
      await pumpEventQueue();
      expect(monitor.watchedContainers, isEmpty);
      await eventBus.dispose();
    });

    test('stop does not launch health checks from a stale multi-authority snapshot', () async {
      final firstInspectStarted = Completer<void>();
      var inspectCalls = 0;
      ContainerManager slowManager(String name) => ContainerManager(
        config: const ContainerConfig(enabled: true, image: 'test:latest'),
        containerName: name,
        profileId: 'workspace',
        workspaceMounts: const [],
        generatedStateDir: '/tmp/dartclaw-state-$name',
        runCommand: (executable, arguments) async {
          if (!arguments.contains('inspect')) return ProcessResult(0, 0, '', '');
          inspectCalls++;
          if (!firstInspectStarted.isCompleted) firstInspectStarted.complete();
          return Completer<ProcessResult>().future;
        },
      );
      final managers = [slowManager('slow-a'), slowManager('slow-b'), slowManager('slow-c')];
      final eventBus = EventBus();
      final monitor = ContainerHealthMonitor(
        eventBus: eventBus,
        interval: const Duration(milliseconds: 1),
        healthCheckTimeout: const Duration(milliseconds: 20),
      );
      for (final manager in managers) {
        monitor.watch(manager.containerName, manager);
      }
      monitor.start();
      await firstInspectStarted.future;

      await monitor.stop();

      expect(inspectCalls, 1, reason: 'stop clears ownership before a stale poll can launch later inspections');
      await eventBus.dispose();
    });

    test('stop cancels periodic timer', () async {
      final manager = _makeManager(profileId: 'workspace', isRunning: () => true);
      final eventBus = EventBus();
      final monitor = ContainerHealthMonitor(eventBus: eventBus, interval: const Duration(milliseconds: 50))
        ..start()
        ..watch(manager.containerName, manager);
      await monitor.stop();

      // After stop, no more polling should happen — verify no crash
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await eventBus.dispose();
    });
  });
}
