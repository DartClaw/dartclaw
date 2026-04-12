import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('ConfigDelta', () {
    late DartclawConfig base;

    setUp(() {
      base = const DartclawConfig.defaults();
    });

    test('hasChanged with exact key match', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {'scheduling.*'});

      expect(delta.hasChanged('scheduling.*'), isTrue);
      expect(delta.hasChanged('guards.*'), isFalse);
    });

    test('hasChanged: specific watch key matches section changed key', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {'scheduling.*'});

      // A specific watch key matches its section glob
      expect(delta.hasChanged('scheduling.heartbeat.enabled'), isTrue);
      expect(delta.hasChanged('scheduling.heartbeatIntervalMinutes'), isTrue);
      // But not a different section
      expect(delta.hasChanged('alerts.enabled'), isFalse);
    });

    test('hasChanged: section glob watch key matches section changed key', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {'security.*'});

      expect(delta.hasChanged('security.*'), isTrue);
      expect(delta.hasChanged('security.guards.enabled'), isTrue);
      expect(delta.hasChanged('workspace.*'), isFalse);
    });

    test('hasChanged with empty changedKeys', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {});

      expect(delta.hasChanged('scheduling.*'), isFalse);
      expect(delta.hasChanged('any.key'), isFalse);
    });

    test('hasChangedAny with mixed keys', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {'scheduling.*', 'security.*'});

      expect(delta.hasChangedAny(['scheduling.*', 'alerts.*']), isTrue);
      expect(delta.hasChangedAny(['alerts.*', 'logging.*']), isFalse);
    });

    test('hasChangedAny with empty keys', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {'scheduling.*'});

      expect(delta.hasChangedAny([]), isFalse);
    });

    test('isEmpty returns true when no changed keys', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {});
      expect(delta.isEmpty, isTrue);
    });

    test('isEmpty returns false when changed keys present', () {
      final delta = ConfigDelta(previous: base, current: base, changedKeys: const {'scheduling.*'});
      expect(delta.isEmpty, isFalse);
    });

    test('multiple changed keys all matchable', () {
      final delta = ConfigDelta(
        previous: base,
        current: base,
        changedKeys: const {'scheduling.*', 'security.*', 'workspace.*'},
      );

      expect(delta.hasChanged('scheduling.*'), isTrue);
      expect(delta.hasChanged('security.*'), isTrue);
      expect(delta.hasChanged('workspace.*'), isTrue);
      expect(delta.hasChanged('logging.*'), isFalse);
    });
  });
}
