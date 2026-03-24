import 'dart:io';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('GET /api/providers', () {
    test('returns 200 with providers, summary counts, and redacted credential details', () async {
      final providerStatus = ProviderStatusService(
        providers: const ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: 'claude', poolSize: 2),
            'codex': ProviderEntry(executable: 'codex', poolSize: 1),
            'ghost': ProviderEntry(executable: 'ghost', poolSize: 1),
          },
        ),
        registry: CredentialRegistry(
          credentials: const CredentialsConfig(
            entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-secret-value')},
          ),
        ),
        defaultProvider: 'claude',
      );

      await providerStatus.probe(
        commandProbe: _probeResults({
          'claude': _probeOk('Claude CLI 4.0.0'),
          'codex': _probeOk('Codex CLI 1.2.0'),
          'ghost': _probeMissing('ghost'),
        }),
        authProbe: (_, {String? providerId}) async => false,
      );

      final response = await providerRoutes(
        providerStatus: providerStatus,
      ).call(Request('GET', Uri.parse('http://localhost/api/providers')));

      expect(response.statusCode, 200);

      final rawBody = await response.readAsString();
      expect(rawBody, isNot(contains('anthropic-secret-value')));

      final json = jsonDecode(rawBody) as Map<String, dynamic>;
      expect(json.keys, containsAll(<String>['providers', 'summary']));

      final providers = (json['providers'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(providers, hasLength(3));
      expect(providers.map((provider) => provider['id']), containsAll(<String>['claude', 'codex', 'ghost']));

      final byId = {for (final provider in providers) provider['id'] as String: provider};

      expect(byId['claude']!['credentialStatus'], 'present');
      expect(byId['claude']!['credentialEnvVar'], 'ANTHROPIC_API_KEY');
      expect(byId['claude']!['isDefault'], isTrue);
      expect(byId['claude']!['health'], 'healthy');

      expect(byId['codex']!['credentialStatus'], 'missing');
      expect(byId['codex']!['credentialEnvVar'], 'OPENAI_API_KEY');
      expect(byId['codex']!['health'], 'degraded');

      expect(byId['ghost']!['credentialStatus'], 'missing');
      expect(byId['ghost']!['health'], 'unavailable');
      expect(byId['ghost']!['errorMessage'], contains("Binary 'ghost' for provider 'ghost' was not found."));

      expect(json['summary'], {'configured': 3, 'healthy': 1, 'degraded': 1});
    });
  });
}

CommandProbe _probeResults(Map<String, CommandProbe> probes) {
  return (executable, arguments) {
    final probe = probes[executable];
    if (probe == null) {
      throw ProcessException(executable, arguments, 'No probe configured for test');
    }
    return probe(executable, arguments);
  };
}

CommandProbe _probeOk(String stdout, {String stderr = ''}) {
  return (executable, arguments) async => ProcessResult(1, 0, stdout, stderr);
}

CommandProbe _probeMissing(String executableName) {
  return (executable, arguments) async => throw ProcessException(executableName, arguments, 'missing binary');
}
