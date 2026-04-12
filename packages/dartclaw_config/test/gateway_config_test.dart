import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

DartclawConfig _loadYaml(String yaml) {
  return DartclawConfig.load(
    fileReader: (path) => path == '/tmp/.dartclaw/dartclaw.yaml' ? yaml : null,
    env: {'HOME': '/tmp'},
  );
}

void main() {
  group('ReloadConfig', () {
    test('defaults when gateway.reload absent', () {
      final config = _loadYaml('port: 3000\n');
      expect(config.gateway.reload.mode, 'signal');
      expect(config.gateway.reload.debounceMs, 500);
    });

    test('parses valid mode: auto', () {
      final config = _loadYaml('''
gateway:
  reload:
    mode: auto
''');
      expect(config.gateway.reload.mode, 'auto');
      expect(config.gateway.reload.debounceMs, 500);
    });

    test('parses valid mode: off', () {
      final config = _loadYaml('''
gateway:
  reload:
    mode: off
''');
      expect(config.gateway.reload.mode, 'off');
    });

    test('parses valid mode: signal', () {
      final config = _loadYaml('''
gateway:
  reload:
    mode: signal
''');
      expect(config.gateway.reload.mode, 'signal');
    });

    test('invalid mode produces warning and uses default', () {
      final config = _loadYaml('''
gateway:
  reload:
    mode: invalid_mode
''');
      expect(config.gateway.reload.mode, 'signal');
      expect(config.warnings, anyElement(contains('gateway.reload.mode')));
    });

    test('parses debounce_ms', () {
      final config = _loadYaml('''
gateway:
  reload:
    mode: auto
    debounce_ms: 1000
''');
      expect(config.gateway.reload.debounceMs, 1000);
    });

    test('debounce_ms below minimum produces warning and uses default', () {
      final config = _loadYaml('''
gateway:
  reload:
    debounce_ms: 50
''');
      expect(config.gateway.reload.debounceMs, 500);
      expect(config.warnings, anyElement(contains('debounce_ms')));
    });

    test('invalid debounce_ms type produces warning and uses default', () {
      final config = _loadYaml('''
gateway:
  reload:
    debounce_ms: "fast"
''');
      expect(config.gateway.reload.debounceMs, 500);
      expect(config.warnings, anyElement(contains('debounce_ms')));
    });
  });

  group('GatewayConfig equality', () {
    test('equal configs with same reload', () {
      const a = GatewayConfig(reload: ReloadConfig(mode: 'auto', debounceMs: 1000));
      const b = GatewayConfig(reload: ReloadConfig(mode: 'auto', debounceMs: 1000));
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different reload modes are not equal', () {
      const a = GatewayConfig(reload: ReloadConfig(mode: 'auto'));
      const b = GatewayConfig(reload: ReloadConfig(mode: 'off'));
      expect(a, isNot(equals(b)));
    });

    test('ReloadConfig defaults match expected values', () {
      const reload = ReloadConfig.defaults();
      expect(reload.mode, 'signal');
      expect(reload.debounceMs, 500);
    });

    test('ReloadConfig value equality', () {
      const a = ReloadConfig(mode: 'auto', debounceMs: 1000);
      const b = ReloadConfig(mode: 'auto', debounceMs: 1000);
      expect(a, equals(b));
    });
  });
}
