import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

/// Creates a ContainerManager with a custom `docker inspect` response.
ContainerManager _makeManager({required String profileId, required bool Function() isRunning}) {
  return ContainerManager(
    config: ContainerConfig(enabled: true, image: 'test:latest'),
    containerName: 'test-$profileId',
    profileId: profileId,
    workspaceMounts: [],
    proxySocketDir: '/tmp',
    runCommand: (executable, arguments) async {
      // Respond to `docker inspect --format {{.State.Running}} <name>`
      if (arguments.contains('inspect')) {
        if (isRunning()) {
          return ProcessResult(0, 0, 'true\n', '');
        }
        return ProcessResult(0, 1, '', 'not running');
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

      final monitor = ContainerHealthMonitor(
        containerManagers: {'workspace': manager},
        eventBus: eventBus,
        interval: const Duration(milliseconds: 50),
      );
      monitor.start();

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

      final monitor = ContainerHealthMonitor(
        containerManagers: {'restricted': manager},
        eventBus: eventBus,
        interval: const Duration(milliseconds: 50),
      );
      monitor.start();

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

      final monitor = ContainerHealthMonitor(
        containerManagers: {'workspace': manager},
        eventBus: eventBus,
        interval: const Duration(milliseconds: 50),
      );
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await monitor.stop();

      expect(events, isEmpty);

      await eventBus.dispose();
    });

    test('stop cancels periodic timer', () async {
      final manager = _makeManager(profileId: 'workspace', isRunning: () => true);
      final eventBus = EventBus();
      final monitor = ContainerHealthMonitor(
        containerManagers: {'workspace': manager},
        eventBus: eventBus,
        interval: const Duration(milliseconds: 50),
      );
      monitor.start();
      await monitor.stop();

      // After stop, no more polling should happen — verify no crash
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await eventBus.dispose();
    });
  });
}
