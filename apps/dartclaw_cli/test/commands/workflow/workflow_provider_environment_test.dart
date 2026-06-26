import 'package:dartclaw_cli/src/commands/workflow/workflow_provider_environment.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show CredentialRegistry, CredentialsConfig;
import 'package:test/test.dart';

void main() {
  CredentialRegistry registry({Map<String, String> env = const {}}) =>
      CredentialRegistry(credentials: const CredentialsConfig(), env: env);

  group('buildWorkflowProviderEnvironment', () {
    test('preserves USER from the parent environment (keychain OAuth invariant)', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        registry: registry(),
        baseEnvironment: const {'USER': 'tobias', 'HOME': '/home/tobias', 'PATH': '/usr/bin'},
      );

      expect(env['USER'], 'tobias');
    });

    test('overlays a configured API key onto its accepted env vars', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'claude',
        registry: registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
      expect(env['USER'], 'tobias');
    });

    test('overlays a family API key for provider aliases', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'my_agent',
        providerFamily: 'codex',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['OPENAI_API_KEY'], 'sk-openai-test');
      expect(env['CODEX_API_KEY'], 'sk-openai-test');
      expect(env['USER'], 'tobias');
    });

    test('resolved family key wins over provider-id key family', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'claude',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test', 'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], 'sk-ant-test');
      expect(env['OPENAI_API_KEY'], isNull);
      expect(env['CODEX_API_KEY'], isNull);
    });

    test('provider-id key does not overlay when resolved family key is missing', () {
      final env = buildWorkflowProviderEnvironment(
        providerId: 'codex',
        providerFamily: 'claude',
        registry: registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}),
        baseEnvironment: const {'USER': 'tobias'},
      );

      expect(env['ANTHROPIC_API_KEY'], isNull);
      expect(env['OPENAI_API_KEY'], isNull);
      expect(env['CODEX_API_KEY'], isNull);
    });
  });
}
