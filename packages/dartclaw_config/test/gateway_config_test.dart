import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('ReloadConfig', () {
    test('defaults when gateway.reload absent', () {
      final config = loadYaml('port: 3000\n');
      expect(config.gateway.reload.mode, 'signal');
      expect(config.gateway.reload.debounceMs, 500);
    });

    test('parses valid mode: auto', () {
      final config = loadYaml('''
gateway:
  reload:
    mode: auto
''');
      expect(config.gateway.reload.mode, 'auto');
      expect(config.gateway.reload.debounceMs, 500);
    });

    test('parses valid mode: off', () {
      final config = loadYaml('''
gateway:
  reload:
    mode: off
''');
      expect(config.gateway.reload.mode, 'off');
    });

    test('parses valid mode: signal', () {
      final config = loadYaml('''
gateway:
  reload:
    mode: signal
''');
      expect(config.gateway.reload.mode, 'signal');
    });

    test('invalid mode produces warning and uses default', () {
      final config = loadYaml('''
gateway:
  reload:
    mode: invalid_mode
''');
      expect(config.gateway.reload.mode, 'signal');
      expect(config.warnings, anyElement(contains('gateway.reload.mode')));
    });

    test('parses debounce_ms', () {
      final config = loadYaml('''
gateway:
  reload:
    mode: auto
    debounce_ms: 1000
''');
      expect(config.gateway.reload.debounceMs, 1000);
    });

    test('debounce_ms below minimum produces warning and uses default', () {
      final config = loadYaml('''
gateway:
  reload:
    debounce_ms: 50
''');
      expect(config.gateway.reload.debounceMs, 500);
      expect(config.warnings, anyElement(contains('debounce_ms')));
    });

    test('invalid debounce_ms type produces warning and uses default', () {
      final config = loadYaml('''
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

  group('gateway/auth flat keys', () {
    test('gateway.hsts defaults to false when unset', () {
      final config = loadNoFile();
      expect(config.gateway.hsts, isFalse);
    });

    test('auth.cookie_secure defaults to false when unset', () {
      final config = loadNoFile();
      expect(config.auth.cookieSecure, isFalse);
    });

    test('auth.trusted_proxies defaults to empty when unset', () {
      final config = loadNoFile();
      expect(config.auth.trustedProxies, isEmpty);
    });

    test('auth.cookie_secure parses when configured', () {
      final config = loadYaml('auth:\n  cookie_secure: true\n');
      expect(config.auth.cookieSecure, isTrue);
    });

    test('auth.trusted_proxies parses when configured', () {
      final config = loadYaml('auth:\n  trusted_proxies:\n    - 192.168.1.100\n    - 192.168.1.101\n');
      expect(config.auth.trustedProxies, ['192.168.1.100', '192.168.1.101']);
    });

    test('auth.cookie_secure invalid type collects warning and uses default', () {
      final config = loadYaml('auth:\n  cookie_secure: yes\n');
      expect(config.auth.cookieSecure, isFalse);
      expect(config.warnings, anyElement(contains('Invalid type for cookie_secure')));
    });

    test('auth.trusted_proxies invalid type collects warning and uses default', () {
      final config = loadYaml('auth:\n  trusted_proxies: 192.168.1.100\n');
      expect(config.auth.trustedProxies, isEmpty);
      expect(config.warnings, anyElement(contains('Invalid type for trusted_proxies')));
    });

    test('gateway.hsts invalid type collects warning and uses default', () {
      final config = loadYaml('gateway:\n  hsts: yes\n');
      expect(config.gateway.hsts, isFalse);
      expect(config.warnings, anyElement(contains('Invalid type for hsts')));
    });
  });
}
