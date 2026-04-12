import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('Config section equality', () {
    group('ServerConfig', () {
      test('equal instances with same fields', () {
        const a = ServerConfig(port: 8080, host: 'example.com', name: 'Test');
        const b = ServerConfig(port: 8080, host: 'example.com', name: 'Test');
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different port are not equal', () {
        const a = ServerConfig(port: 3000);
        const b = ServerConfig(port: 8080);
        expect(a, isNot(equals(b)));
      });

      test('different host are not equal', () {
        const a = ServerConfig(host: 'localhost');
        const b = ServerConfig(host: '0.0.0.0');
        expect(a, isNot(equals(b)));
      });
    });

    group('SchedulingConfig', () {
      test('equal instances match', () {
        const a = SchedulingConfig(heartbeatEnabled: false, heartbeatIntervalMinutes: 10);
        const b = SchedulingConfig(heartbeatEnabled: false, heartbeatIntervalMinutes: 10);
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different heartbeatEnabled are not equal', () {
        const a = SchedulingConfig(heartbeatEnabled: true);
        const b = SchedulingConfig(heartbeatEnabled: false);
        expect(a, isNot(equals(b)));
      });
    });

    group('SecurityConfig', () {
      test('equal default instances match', () {
        const a = SecurityConfig.defaults();
        const b = SecurityConfig.defaults();
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different contentGuardEnabled are not equal', () {
        const a = SecurityConfig(contentGuardEnabled: true);
        const b = SecurityConfig(contentGuardEnabled: false);
        expect(a, isNot(equals(b)));
      });
    });

    group('AgentConfig', () {
      test('equal defaults match', () {
        const a = AgentConfig.defaults();
        const b = AgentConfig.defaults();
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different provider are not equal', () {
        const a = AgentConfig(provider: 'claude');
        const b = AgentConfig(provider: 'codex');
        expect(a, isNot(equals(b)));
      });
    });

    group('WorkspaceConfig', () {
      test('equal instances match', () {
        const a = WorkspaceConfig(gitSyncEnabled: false);
        const b = WorkspaceConfig(gitSyncEnabled: false);
        expect(a, equals(b));
      });

      test('different gitSyncEnabled are not equal', () {
        const a = WorkspaceConfig(gitSyncEnabled: true);
        const b = WorkspaceConfig(gitSyncEnabled: false);
        expect(a, isNot(equals(b)));
      });
    });

    group('ContextConfig', () {
      test('equal instances match', () {
        const a = ContextConfig(reserveTokens: 10000, warningThreshold: 90);
        const b = ContextConfig(reserveTokens: 10000, warningThreshold: 90);
        expect(a, equals(b));
      });
    });

    group('MemoryConfig', () {
      test('equal instances match', () {
        const a = MemoryConfig(maxBytes: 64 * 1024);
        const b = MemoryConfig(maxBytes: 64 * 1024);
        expect(a, equals(b));
      });
    });

    group('UsageConfig', () {
      test('equal instances match', () {
        const a = UsageConfig(budgetWarningTokens: 50000);
        const b = UsageConfig(budgetWarningTokens: 50000);
        expect(a, equals(b));
      });
    });

    group('LoggingConfig', () {
      test('equal instances match', () {
        const a = LoggingConfig(format: 'json', level: 'DEBUG');
        const b = LoggingConfig(format: 'json', level: 'DEBUG');
        expect(a, equals(b));
      });

      test('different format are not equal', () {
        const a = LoggingConfig(format: 'json');
        const b = LoggingConfig(format: 'human');
        expect(a, isNot(equals(b)));
      });
    });
  });
}
