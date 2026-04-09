import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

DartclawConfig _load(String yaml) => DartclawConfig.load(
  fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
  env: {'HOME': '/tmp'},
);

void main() {
  group('AlertsConfig.defaults()', () {
    test('has enabled=false, cooldownSeconds=300, burstThreshold=5, empty targets and routes', () {
      const defaults = AlertsConfig.defaults();
      expect(defaults.enabled, isFalse);
      expect(defaults.cooldownSeconds, 300);
      expect(defaults.burstThreshold, 5);
      expect(defaults.targets, isEmpty);
      expect(defaults.routes, isEmpty);
    });
  });

  group('AlertsConfig equality', () {
    test('two configs with same values are ==', () {
      const a = AlertsConfig(
        enabled: true,
        cooldownSeconds: 60,
        burstThreshold: 3,
        targets: [AlertTarget(channel: 'whatsapp', recipient: '+1234')],
        routes: {'guard_block': ['0']},
      );
      const b = AlertsConfig(
        enabled: true,
        cooldownSeconds: 60,
        burstThreshold: 3,
        targets: [AlertTarget(channel: 'whatsapp', recipient: '+1234')],
        routes: {'guard_block': ['0']},
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('configs with different enabled are !=', () {
      const a = AlertsConfig(enabled: true);
      const b = AlertsConfig(enabled: false);
      expect(a, isNot(equals(b)));
    });

    test('configs with different targets are !=', () {
      const a = AlertsConfig(targets: [AlertTarget(channel: 'signal', recipient: '+1')]);
      const b = AlertsConfig(targets: [AlertTarget(channel: 'signal', recipient: '+2')]);
      expect(a, isNot(equals(b)));
    });

    test('target list order matters for equality', () {
      const t1 = AlertTarget(channel: 'whatsapp', recipient: '+1');
      const t2 = AlertTarget(channel: 'signal', recipient: '+2');
      const a = AlertsConfig(targets: [t1, t2]);
      const b = AlertsConfig(targets: [t2, t1]);
      expect(a, isNot(equals(b)));
    });
  });

  group('AlertTarget equality', () {
    test('same channel and recipient are ==', () {
      const a = AlertTarget(channel: 'whatsapp', recipient: '+1234');
      const b = AlertTarget(channel: 'whatsapp', recipient: '+1234');
      expect(a, equals(b));
    });

    test('different recipient are !=', () {
      const a = AlertTarget(channel: 'whatsapp', recipient: '+1234');
      const b = AlertTarget(channel: 'whatsapp', recipient: '+9999');
      expect(a, isNot(equals(b)));
    });
  });

  group('DartclawConfig.load() alerts section', () {
    test('defaults applied when alerts section is absent', () {
      final config = _load('port: 3000');
      expect(config.alerts.enabled, isFalse);
      expect(config.alerts.targets, isEmpty);
      expect(config.alerts.routes, isEmpty);
    });

    test('parses enabled, cooldown_seconds, burst_threshold', () {
      final config = _load('''
alerts:
  enabled: true
  cooldown_seconds: 120
  burst_threshold: 10
''');
      expect(config.alerts.enabled, isTrue);
      expect(config.alerts.cooldownSeconds, 120);
      expect(config.alerts.burstThreshold, 10);
    });

    test('parses targets with channel and recipient', () {
      final config = _load('''
alerts:
  enabled: true
  targets:
    - channel: whatsapp
      recipient: "+1234567890"
    - channel: signal
      recipient: "+0987654321"
''');
      expect(config.alerts.targets, hasLength(2));
      expect(config.alerts.targets[0].channel, 'whatsapp');
      expect(config.alerts.targets[0].recipient, '+1234567890');
      expect(config.alerts.targets[1].channel, 'signal');
    });

    test('parses routes with event type keys', () {
      final config = _load('''
alerts:
  enabled: true
  targets:
    - channel: whatsapp
      recipient: "+1234"
  routes:
    guard_block: ["0"]
    compaction: ["*"]
''');
      expect(config.alerts.routes['guard_block'], ['0']);
      expect(config.alerts.routes['compaction'], ['*']);
    });

    test('missing target channel produces warning and skips entry', () {
      final config = _load('''
alerts:
  targets:
    - recipient: "+1234"
''');
      expect(config.alerts.targets, isEmpty);
      expect(config.warnings.any((w) => w.contains('channel')), isTrue);
    });

    test('missing target recipient produces warning and skips entry', () {
      final config = _load('''
alerts:
  targets:
    - channel: whatsapp
''');
      expect(config.alerts.targets, isEmpty);
      expect(config.warnings.any((w) => w.contains('recipient')), isTrue);
    });

    test('non-map target entry produces warning and is skipped', () {
      final config = _load('''
alerts:
  targets:
    - just_a_string
''');
      expect(config.alerts.targets, isEmpty);
      expect(config.warnings, isNotEmpty);
    });

    test('routes with unknown event type accepted as-is (no warning)', () {
      final config = _load('''
alerts:
  routes:
    some_future_event_type: ["*"]
''');
      expect(config.alerts.routes['some_future_event_type'], ['*']);
    });

    test('empty targets list with enabled=true is valid', () {
      final config = _load('''
alerts:
  enabled: true
  targets: []
''');
      expect(config.alerts.enabled, isTrue);
      expect(config.alerts.targets, isEmpty);
    });

    test('invalid enabled type produces warning, uses default', () {
      final config = _load('''
alerts:
  enabled: "yes"
''');
      expect(config.alerts.enabled, isFalse);
      expect(config.warnings.any((w) => w.contains('alerts.enabled')), isTrue);
    });

    test('cooldown_seconds < 1 produces warning, uses default', () {
      final config = _load('''
alerts:
  cooldown_seconds: 0
''');
      expect(config.alerts.cooldownSeconds, 300);
      expect(config.warnings.any((w) => w.contains('cooldown_seconds')), isTrue);
    });
  });
}
