import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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

    test('debounce_ms below its bound keeps its exact warning and section default', () {
      final config = loadYaml('''
gateway:
  reload:
    debounce_ms: 50
''');

      expect(config.gateway.reload.debounceMs, 500);
      expect(config.warnings, ['gateway.reload.debounce_ms must be >= 100, got 50 — using default 500']);
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

  group('gateway.token env substitution', () {
    // An undefined `${VAR}` resolves to an empty string. Storing that as the
    // token hands the gateway a credential an empty bearer header satisfies and
    // an empty HMAC key that signs forgeable session cookies, so the reference
    // must read as absent and let the generated token file take over.
    test('unresolved reference reads as unset, not as an empty token', () {
      final config = loadYaml('gateway:\n  auth_mode: token\n  token: \${DARTCLAW_TOKEN}\n');
      expect(config.gateway.token, isNull);
      expect(config.warnings, anyElement(allOf(contains('gateway.token'), contains('\${DARTCLAW_TOKEN}'))));
    });

    test('unresolved reference blocks hot reload', () {
      final config = loadYaml('gateway:\n  auth_mode: token\n  token: \${DARTCLAW_TOKEN}\n');
      expect(config.reloadBlockingWarnings, anyElement(contains('gateway.token')));
    });

    test('resolved reference becomes the token', () {
      final config = loadYaml(
        'gateway:\n  auth_mode: token\n  token: \${DARTCLAW_TOKEN}\n',
        env: const {'HOME': defaultTestHome, 'DARTCLAW_TOKEN': 'resolved-token'},
      );
      expect(config.gateway.token, 'resolved-token');
      expect(config.warnings, isEmpty);
    });

    test('reference resolving to whitespace reads as unset', () {
      final config = loadYaml(
        'gateway:\n  auth_mode: token\n  token: "\${DARTCLAW_TOKEN} "\n',
        env: const {'HOME': defaultTestHome},
      );
      expect(config.gateway.token, isNull);
      expect(config.warnings, anyElement(contains('gateway.token')));
    });

    test('literal token is preserved', () {
      final config = loadYaml('gateway:\n  auth_mode: token\n  token: literal-token\n');
      expect(config.gateway.token, 'literal-token');
      expect(config.warnings, isEmpty);
    });

    test('omitted token stays unset without warning', () {
      final config = loadYaml('gateway:\n  auth_mode: token\n');
      expect(config.gateway.token, isNull);
      expect(config.warnings, isEmpty);
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

  group('gateway.auth_mode', () {
    // Declared enum_ over the two values the loader accepts. It is readonly, so
    // the write path is unchanged; the load path is unchanged too.
    test('parses both modes', () {
      expect(loadYaml('gateway:\n  auth_mode: none\n').gateway.authMode, 'none');
      expect(loadYaml('gateway:\n  auth_mode: token\n').gateway.authMode, 'token');
    });

    test('an unknown mode still warns and falls back to the default', () {
      final config = loadYaml('gateway:\n  auth_mode: basic\n');
      expect(config.gateway.authMode, 'token');
      expect(config.warnings, anyElement('Invalid gateway.auth_mode: "basic" — using default'));
    });
  });

  group('gateway.mcp_clients', () {
    String yaml(String clients, {String authMode = 'token'}) =>
        'gateway:\n  auth_mode: $authMode\n  token: gateway-secret\n  mcp_clients:\n$clients';

    const ideClient = '    - name: ide\n      token: \${DARTCLAW_MCP_CLIENT_IDE}\n';
    const env = {'HOME': defaultTestHome, 'DARTCLAW_MCP_CLIENT_IDE': 'ide-secret'};

    test('absent by default, so /mcp keeps accepting the gateway token alone', () {
      expect(loadNoFile().gateway.mcpClients, isEmpty);
    });

    test('a reference-form client resolves its token and keeps the reference name', () {
      final config = loadYaml(yaml(ideClient), env: env);

      expect(config.gateway.mcpClients, hasLength(1));
      final client = config.gateway.mcpClients.single;
      expect(client.name, 'ide');
      expect(client.tokenReference, r'${DARTCLAW_MCP_CLIENT_IDE}');
      expect(client.token, 'ide-secret');
    });

    test('a literal token is refused, because a literal cannot be rotated out of the config file', () {
      expect(
        () => loadYaml(yaml('    - name: ide\n      token: ide-secret\n'), env: env),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', allOf(contains('"ide"'), contains(r'${VAR}'))),
        ),
      );
    });

    test('an unset reference is refused rather than authenticating the empty string', () {
      expect(
        () => loadYaml(yaml(ideClient), env: const {'HOME': defaultTestHome}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"ide"'), contains('resolves to nothing')),
          ),
        ),
      );
    });

    test('two clients sharing one token are refused, since the audit principal would be a guess', () {
      expect(
        () => loadYaml(
          yaml('$ideClient    - name: docs\n      token: \${DARTCLAW_MCP_CLIENT_DOCS}\n'),
          env: {...env, 'DARTCLAW_MCP_CLIENT_DOCS': 'ide-secret'},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"ide"'), contains('"docs"'), contains('share one token')),
          ),
        ),
      );
    });

    test('a duplicate client name is refused', () {
      expect(
        () => loadYaml(
          yaml('$ideClient    - name: ide\n      token: \${DARTCLAW_MCP_CLIENT_DOCS}\n'),
          env: {...env, 'DARTCLAW_MCP_CLIENT_DOCS': 'docs-secret'},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"ide"'), contains('more than once')),
          ),
        ),
      );
    });

    test('a client token equal to the gateway token is refused', () {
      expect(
        () => loadYaml(yaml(ideClient), env: {...env, 'DARTCLAW_MCP_CLIENT_IDE': 'gateway-secret'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"ide"'), contains('gateway token')),
          ),
        ),
      );
    });

    test('a client under auth_mode: none is refused, since the instance authenticates nothing', () {
      expect(
        () => loadYaml(yaml(ideClient, authMode: 'none'), env: env),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('auth_mode: token'))),
      );
    });

    test('a client without a name is refused', () {
      expect(
        () => loadYaml(yaml('    - token: \${DARTCLAW_MCP_CLIENT_IDE}\n'), env: env),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('name is required'))),
      );
    });

    test('a client without a token is refused', () {
      expect(
        () => loadYaml(yaml('    - name: ide\n'), env: env),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"ide"'), contains('missing a token')),
          ),
        ),
      );
    });

    test('clients participate in gateway equality, so a changed client list is a config change', () {
      const a = GatewayConfig(
        mcpClients: [McpClientConfig(name: 'ide', tokenReference: r'${A}', token: 'one')],
      );
      const b = GatewayConfig(
        mcpClients: [McpClientConfig(name: 'ide', tokenReference: r'${A}', token: 'one')],
      );
      const c = GatewayConfig(
        mcpClients: [McpClientConfig(name: 'ide', tokenReference: r'${A}', token: 'two')],
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
