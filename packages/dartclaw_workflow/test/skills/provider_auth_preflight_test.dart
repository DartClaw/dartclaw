import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

CredentialRegistry _registry({
  Map<String, String> env = const {},
  Map<String, CredentialEntry> subscriptions = const {},
  ProvidersConfig providers = const ProvidersConfig.defaults(),
}) => CredentialRegistry(
  credentials: const CredentialsConfig(),
  env: env,
  providers: providers,
  subscriptions: subscriptions,
);

void main() {
  group('CliProviderAuthPreflight claude', () {
    test('a stored setup-token short-circuits without spawning the CLI', () async {
      // Probing here would ask the operator's interactive login whether *it* is
      // signed in — an answer about a different credential than the one the run
      // will actually present.
      var invoked = false;
      final preflight = CliProviderAuthPreflight(
        credentials: () =>
            _registry(subscriptions: const {'claude': CredentialEntry.subscription(token: 'sk-ant-oat01-stored')}),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 0, '{"loggedIn":false}', '');
        },
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.authenticated, isTrue);
      expect(invoked, isFalse);
    });

    test('a key ruled out by auth: subscription does not short-circuit', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(
          env: {'ANTHROPIC_API_KEY': 'sk-ant-test'},
          providers: ProvidersConfig(
            entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription)},
          ),
        ),
        runner: (executable, arguments, {environment}) async => ProcessResult(1, 0, '{"loggedIn":false}', ''),
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.authenticated, isFalse);
    });

    test('logged-out claude is unauthenticated with actionable remediation', () async {
      final calls = <List<String>>[];
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async {
          calls.add([executable, ...arguments]);
          return ProcessResult(1, 0, '{"loggedIn":false}', '');
        },
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.authenticated, isFalse);
      expect(result.remediationMessage, contains('claude setup-token'));
      expect(result.remediationMessage, contains('ANTHROPIC_API_KEY'));
      expect(calls, [
        ['claude', 'auth', 'status'],
      ]);
    });

    test('configured ANTHROPIC_API_KEY short-circuits without spawning the CLI', () async {
      var invoked = false;
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 0, '{"loggedIn":false}', '');
        },
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.authenticated, isTrue);
      expect(invoked, isFalse);
    });

    test('resolved claude family ignores codex provider API keys', () async {
      var invoked = false;
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 0, '{"loggedIn":false}', '');
        },
      );

      final result = await preflight.evaluate(provider: 'codex', providerOptions: {'family': 'claude'});

      expect(result.authenticated, isFalse);
      expect(invoked, isTrue);
      expect(result.remediationMessage, contains('ANTHROPIC_API_KEY'));
      expect(result.remediationMessage, isNot(contains('OPENAI_API_KEY')));
    });

    test('configured ANTHROPIC_API_KEY short-circuits a claude family override', () async {
      var invoked = false;
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(env: {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 0, '{"loggedIn":false}', '');
        },
      );

      final result = await preflight.evaluate(provider: 'codex', providerOptions: {'family': 'claude'});

      expect(result.authenticated, isTrue);
      expect(invoked, isFalse);
    });

    test('logged-in claude is authenticated', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async =>
            ProcessResult(1, 0, '{"loggedIn":true,"authMethod":"oauth"}', ''),
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.authenticated, isTrue);
      expect(result.remediationMessage, isNull);
    });
  });

  group('CliProviderAuthPreflight credential precedence', () {
    const storedSubscription = CredentialEntry.subscription(token: 'sk-ant-oat01-stored');

    test('a stored subscription credential preflights as authenticated without spawning the CLI', () async {
      var invoked = false;
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(subscriptions: const {'claude': storedSubscription}),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 0, '{"loggedIn":false}', '');
        },
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.authenticated, isTrue);
      expect(invoked, isFalse);
    });

    test('a forced subscription selection is refused without a CLI probe when none is stored', () async {
      var invoked = false;
      const providers = ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription)},
      );
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(env: const {'ANTHROPIC_API_KEY': 'sk-ant-test'}, providers: providers),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 0, '{"loggedIn":true}', '');
        },
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.authenticated, isFalse);
      expect(invoked, isFalse);
      expect(result.remediationMessage, contains('auth: subscription'));
      expect(result.remediationMessage, isNot(contains('ANTHROPIC_API_KEY')));
    });

    test('a forced API-key selection is refused without a CLI probe when none is configured', () async {
      var invoked = false;
      const providers = ProvidersConfig(
        entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.apiKey)},
      );
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(subscriptions: const {'codex': storedSubscription}, providers: providers),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 0, 'Logged in', '');
        },
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isFalse);
      expect(invoked, isFalse);
      expect(result.remediationMessage, contains('auth: api_key'));
      expect(result.remediationMessage, isNot(contains('codex login')));
    });

    test('no remediation reproduces credential material', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async => ProcessResult(1, 1, '', 'Not logged in'),
      );

      final result = await preflight.evaluate(provider: 'claude');

      expect(result.remediationMessage, isNot(contains('sk-ant')));
    });
  });

  group('CliProviderAuthPreflight codex', () {
    test('logged-out codex (exit 1, message on stderr) is unauthenticated with remediation', () async {
      final calls = <List<String>>[];
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async {
          calls.add([executable, ...arguments]);
          // Real `codex login status` writes "Not logged in" to stderr, exit 1.
          return ProcessResult(1, 1, '', 'Not logged in');
        },
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isFalse);
      expect(result.remediationMessage, contains('codex login'));
      expect(result.remediationMessage, contains('OPENAI_API_KEY'));
      expect(result.remediationMessage, contains('CODEX_API_KEY'));
      expect(calls, [
        ['codex', 'login', 'status'],
      ]);
    });

    test('exit-0 codex that still reports not-logged-in fails closed', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async => ProcessResult(1, 0, 'Not logged in', ''),
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isFalse);
    });

    test('configured OPENAI_API_KEY short-circuits without spawning the CLI', () async {
      var invoked = false;
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 1, 'Not logged in', '');
        },
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isTrue);
      expect(invoked, isFalse);
    });

    test('configured OPENAI_API_KEY short-circuits a codex provider alias without spawning the CLI', () async {
      var invoked = false;
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(env: {'OPENAI_API_KEY': 'sk-openai-test'}),
        runner: (executable, arguments, {environment}) async {
          invoked = true;
          return ProcessResult(1, 1, 'Not logged in', '');
        },
      );

      final result = await preflight.evaluate(provider: 'my_agent', providerOptions: {'family': 'codex'});

      expect(result.authenticated, isTrue);
      expect(invoked, isFalse);
    });

    test('codex provider alias remediation names codex API-key environment variables', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async => ProcessResult(1, 1, '', 'Not logged in'),
      );

      final result = await preflight.evaluate(provider: 'my_agent', providerOptions: {'family': 'codex'});

      expect(result.authenticated, isFalse);
      expect(result.remediationMessage, contains('codex login'));
      expect(result.remediationMessage, contains('OPENAI_API_KEY'));
      expect(result.remediationMessage, contains('CODEX_API_KEY'));
    });

    test('runner exception is reported as unauthenticated with remediation', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async {
          throw const ProcessException('codex', ['login', 'status']);
        },
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isFalse);
      expect(result.remediationMessage, contains('codex login'));
      expect(result.remediationMessage, contains('OPENAI_API_KEY'));
    });

    test('exit-0 codex with unrecognized output fails closed', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async => ProcessResult(1, 0, '', ''),
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isFalse);
    });

    test('exit-0 codex with unauthenticated output fails closed', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async => ProcessResult(1, 0, 'Unauthenticated', ''),
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isFalse);
    });

    test('logged-in codex (exit 0, "Logged in") is authenticated', () async {
      final preflight = CliProviderAuthPreflight(
        credentials: () => _registry(),
        runner: (executable, arguments, {environment}) async => ProcessResult(1, 0, 'Logged in using ChatGPT', ''),
      );

      final result = await preflight.evaluate(provider: 'codex');

      expect(result.authenticated, isTrue);
    });
  });
}
