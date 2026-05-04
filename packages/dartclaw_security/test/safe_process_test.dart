import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

final class _FakePlan implements ProcessEnvironmentPlan {
  @override
  final Map<String, String> environment;

  const _FakePlan(this.environment);
}

void main() {
  group('SafeProcess.sanitize', () {
    test('strips default sensitive patterns and preserves non-sensitive env', () {
      final env = SafeProcess.sanitize(
        baseEnvironment: const {
          'PATH': '/usr/bin',
          'HOME': '/tmp/home',
          'ANTHROPIC_API_KEY': 'secret',
          'GITHUB_TOKEN': 'ghs_secret',
          'CUSTOM_SECRET': 'bad',
          'SAFE_VAR': 'ok',
        },
      );

      expect(env['PATH'], '/usr/bin');
      expect(env['HOME'], '/tmp/home');
      expect(env['SAFE_VAR'], 'ok');
      expect(env.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(env.containsKey('GITHUB_TOKEN'), isFalse);
      expect(env.containsKey('CUSTOM_SECRET'), isFalse);
    });

    test('applies allowlist after stripping sensitive entries', () {
      final env = SafeProcess.sanitize(
        baseEnvironment: const {
          'PATH': '/usr/bin',
          'HOME': '/tmp/home',
          'LANG': 'en_US.UTF-8',
          'LC_ALL': 'en_US.UTF-8',
          'SAFE_VAR': 'drop-me',
          'OPENAI_API_KEY': 'secret',
        },
        allowlist: const ['PATH', 'HOME', 'LC_*'],
        extraEnvironment: const {'CUSTOM_ALLOWED': 'yes'},
      );

      expect(env, {'PATH': '/usr/bin', 'HOME': '/tmp/home', 'LC_ALL': 'en_US.UTF-8', 'CUSTOM_ALLOWED': 'yes'});
    });
  });

  group('SafeProcess.run', () {
    test('uses includeParentEnvironment=false for explicit passthrough env', () async {
      final result = await SafeProcess.run('/bin/sh', const [
        '-c',
        r'printf "%s" "${ANTHROPIC_API_KEY:-missing}"',
      ], env: const EnvPolicy.passthrough(environment: {'PATH': '/usr/bin:/bin'}));

      expect(result.exitCode, 0);
      expect(result.stdout, 'missing');
    });

    test('builds credential-plan env from git baseline and overlay', () async {
      final result = await SafeProcess.run(
        '/bin/sh',
        const ['-c', r'printf "%s|%s|%s" "${PATH:-}" "${GIT_ASKPASS:-}" "${GIT_CONFIG_NOSYSTEM:-}"'],
        env: EnvPolicy.credentialPlan(plan: const _FakePlan({'GIT_ASKPASS': '/tmp/askpass'}), noSystemConfig: true),
        baseEnvironment: const {
          'PATH': '/usr/bin:/bin',
          'HOME': '/tmp/home',
          'LANG': 'en_US.UTF-8',
          'ANTHROPIC_API_KEY': 'leak',
        },
      );

      expect(result.exitCode, 0);
      expect(result.stdout, '/usr/bin:/bin|/tmp/askpass|1');
    });
  });
}
