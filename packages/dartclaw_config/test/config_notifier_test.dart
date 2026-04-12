import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

/// Test double for [Reconfigurable].
class _FakeReconfigurable implements Reconfigurable {
  final Set<String> _watchKeys;
  final bool shouldThrow;

  final List<ConfigDelta> received = [];

  _FakeReconfigurable(this._watchKeys, {this.shouldThrow = false});

  @override
  Set<String> get watchKeys => _watchKeys;

  @override
  void reconfigure(ConfigDelta delta) {
    if (shouldThrow) throw StateError('reconfigure failed');
    received.add(delta);
  }
}

DartclawConfig _withScheduling({bool heartbeatEnabled = true}) {
  return DartclawConfig(scheduling: SchedulingConfig(heartbeatEnabled: heartbeatEnabled));
}

DartclawConfig _withServer({int port = 3000, String host = 'localhost', String? name}) {
  return DartclawConfig(
    server: ServerConfig(port: port, host: host, name: name ?? 'DartClaw'),
  );
}

void main() {
  group('ConfigNotifier', () {
    late DartclawConfig base;
    late ConfigNotifier notifier;

    setUp(() {
      base = const DartclawConfig.defaults();
      notifier = ConfigNotifier(base);
    });

    test('holds initial config', () {
      expect(notifier.current, same(base));
    });

    test('reload with no changes returns null', () {
      final delta = notifier.reload(const DartclawConfig.defaults());
      expect(delta, isNull);
    });

    test('reload with changed scheduling section notifies matching service', () {
      final service = _FakeReconfigurable({'scheduling.*'});
      notifier.register(service);

      final updated = _withScheduling(heartbeatEnabled: false);
      final delta = notifier.reload(updated);

      expect(delta, isNotNull);
      expect(delta!.changedKeys, contains('scheduling.*'));
      expect(service.received, hasLength(1));
      expect(service.received.first.current.scheduling.heartbeatEnabled, isFalse);
    });

    test('reload does NOT notify service with non-matching watchKeys', () {
      final schedulingService = _FakeReconfigurable({'scheduling.*'});
      final guardsService = _FakeReconfigurable({'security.*'});
      notifier
        ..register(schedulingService)
        ..register(guardsService);

      final updated = _withScheduling(heartbeatEnabled: false);
      notifier.reload(updated);

      expect(schedulingService.received, hasLength(1));
      expect(guardsService.received, isEmpty);
    });

    test('unregistered service is not notified', () {
      final service = _FakeReconfigurable({'scheduling.*'});
      notifier.register(service);
      notifier.unregister(service);

      notifier.reload(_withScheduling(heartbeatEnabled: false));

      expect(service.received, isEmpty);
    });

    test('register same service twice causes only one notification', () {
      final service = _FakeReconfigurable({'scheduling.*'});
      notifier.register(service);
      notifier.register(service); // duplicate

      notifier.reload(_withScheduling(heartbeatEnabled: false));

      expect(service.received, hasLength(1));
    });

    test('reload with only non-reloadable server changes returns null delta', () {
      final initial = _withServer(port: 3000, host: 'localhost');
      notifier = ConfigNotifier(initial);

      final service = _FakeReconfigurable({'server.*'});
      notifier.register(service);

      // Change only port (non-reloadable)
      final updated = _withServer(port: 9999, host: 'localhost');
      final delta = notifier.reload(updated);

      expect(delta, isNull);
      expect(service.received, isEmpty);
    });

    test('reload with server non-reloadable and reloadable changes includes server.* in delta', () {
      final initial = _withServer(port: 3000, host: 'localhost', name: 'Old');
      notifier = ConfigNotifier(initial);

      final service = _FakeReconfigurable({'server.*'});
      notifier.register(service);

      // Change port (non-reloadable) AND name (reloadable)
      final updated = _withServer(port: 9999, host: 'localhost', name: 'New');
      final delta = notifier.reload(updated);

      expect(delta, isNotNull);
      expect(delta!.changedKeys, contains('server.*'));
      expect(service.received, hasLength(1));
    });

    test('best-effort: throwing service does not prevent other services from being notified', () {
      final throwingService = _FakeReconfigurable({'scheduling.*'}, shouldThrow: true);
      final goodService1 = _FakeReconfigurable({'scheduling.*'});
      final goodService2 = _FakeReconfigurable({'scheduling.*'});

      notifier
        ..register(goodService1)
        ..register(throwingService)
        ..register(goodService2);

      final updated = _withScheduling(heartbeatEnabled: false);
      final delta = notifier.reload(updated);

      expect(delta, isNotNull);
      expect(goodService1.received, hasLength(1));
      expect(goodService2.received, hasLength(1));
    });

    test('reload updates current config', () {
      final updated = _withScheduling(heartbeatEnabled: false);
      notifier.reload(updated);

      expect(notifier.current, same(updated));
    });

    test('delta contains correct previous and current config', () {
      final updated = _withScheduling(heartbeatEnabled: false);
      final delta = notifier.reload(updated)!;

      expect(delta.previous, same(base));
      expect(delta.current, same(updated));
    });

    test('reload with multiple changed sections includes all in delta', () {
      final service = _FakeReconfigurable({'scheduling.*', 'workspace.*'});
      notifier.register(service);

      final updated = DartclawConfig(
        scheduling: const SchedulingConfig(heartbeatEnabled: false),
        workspace: const WorkspaceConfig(gitSyncEnabled: false),
      );
      final delta = notifier.reload(updated);

      expect(delta, isNotNull);
      expect(delta!.changedKeys, containsAll(['scheduling.*', 'workspace.*']));
      expect(service.received, hasLength(1));
    });
  });
}
