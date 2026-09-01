import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('search.qmd config', () {
    for (final host in ['localhost', '127.0.0.1', '127.42.0.9', '::1', '[::1]']) {
      test('accepts loopback host $host', () {
        final config = loadYaml('search:\n  qmd:\n    host: "$host"\n');
        expect(config.search.qmdHost, host == '[::1]' ? '::1' : host);
        expect(config.warnings, isEmpty);
      });
    }

    for (final host in ['0.0.0.0', '192.168.1.2', 'localhost.example', '127.0.0.256']) {
      test('rejects non-loopback host $host', () {
        final config = loadYaml('search:\n  qmd:\n    host: "$host"\n');
        expect(config.search.qmdHost, '127.0.0.1');
        expect(config.warnings, anyElement(contains('search.qmd.host')));
      });
    }
  });

  group('search.providers config', () {
    test('no providers section returns empty map', () {
      final config = loadYaml('search:\n  backend: fts5\n');
      expect(config.search.providers, isEmpty);
      expect(config.warnings, isEmpty);
    });

    test('no search section returns empty providers', () {
      final config = loadNoFile();
      expect(config.search.providers, isEmpty);
    });

    test('single provider enabled with API key parsed correctly', () {
      final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: true\n      api_key: my-key\n');
      expect(config.search.providers, hasLength(1));
      expect(config.search.providers['brave']!.enabled, isTrue);
      expect(config.search.providers['brave']!.apiKey, 'my-key');
    });

    // Same class of failure as gateway.token: an undefined `${VAR}` resolves to
    // an empty string, and registering a provider with a blank key spawns
    // outbound search calls that can only fail upstream.
    test('provider whose api_key reference resolves empty is skipped', () {
      final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: true\n      api_key: \${BRAVE_KEY}\n');
      expect(config.search.providers, isEmpty);
      expect(config.warnings, anyElement(allOf(contains('search.providers.brave'), contains('api_key'))));
    });

    test('provider whose api_key reference resolves is kept', () {
      final config = loadYaml(
        'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: \${BRAVE_KEY}\n',
        env: const {'HOME': defaultTestHome, 'BRAVE_KEY': 'brave-key'},
      );
      expect(config.search.providers['brave']!.apiKey, 'brave-key');
      expect(config.warnings, isEmpty);
    });

    test('multiple providers parsed', () {
      final config = loadYaml(
        'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: brave-key\n'
        '    tavily:\n      enabled: false\n      api_key: tavily-key\n',
      );
      expect(config.search.providers, hasLength(2));
      expect(config.search.providers['brave']!.enabled, isTrue);
      expect(config.search.providers['tavily']!.enabled, isFalse);
      expect(config.search.providers['tavily']!.apiKey, 'tavily-key');
    });

    test('provider with enabled: false parsed with enabled=false', () {
      final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: false\n      api_key: key\n');
      expect(config.search.providers['brave']!.enabled, isFalse);
    });

    test('provider declaring neither api_key nor credential is skipped with a warning', () {
      final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: true\n');
      expect(config.search.providers, isEmpty);
      expect(config.warnings, anyElement(contains('missing "api_key"')));
      expect(config.warnings, anyElement(contains('credential')));
    });

    test('provider with env var api_key substituted', () {
      final config = loadYaml(
        'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: \${BRAVE_API_KEY}\n',
        env: const {'HOME': defaultTestHome, 'BRAVE_API_KEY': 'resolved-key'},
      );
      expect(config.search.providers['brave']!.apiKey, 'resolved-key');
    });

    test('invalid providers type produces warning', () {
      final config = loadYaml('search:\n  providers: not-a-map\n');
      expect(config.search.providers, isEmpty);
      expect(config.warnings, anyElement(contains('Invalid type for providers')));
    });
  });

  group('search.providers.<id>.credential', () {
    const braveCredential = 'search:\n  providers:\n    brave:\n      enabled: true\n      credential: brave-search\n';

    test('resolves a stored credential into the existing apiKey field', () {
      registerStoredCredentials(const {'brave-search': CredentialEntry(apiKey: 'stored-brave-key')});

      final config = loadYaml(braveCredential);
      expect(config.search.providers['brave']?.apiKey, 'stored-brave-key');
      expect(config.search.providers['brave']?.enabled, isTrue);
      expect(config.warnings, isEmpty);
    });

    test('resolves a config-declared credential too — the reference is to the merged registry', () {
      final config = loadYaml(
        'credentials:\n  brave-search:\n    api_key: \${BRAVE_KEY}\n$braveCredential',
        env: const {'HOME': defaultTestHome, 'BRAVE_KEY': 'from-env'},
      );
      expect(config.search.providers['brave']?.apiKey, 'from-env');
    });

    // A provider left in the map with a blank apiKey is absorbed silently by
    // the `apiKey.isEmpty` guard at the wiring site, so the operator sees the
    // provider disappear with no warning at all. Dropping it here is what makes
    // the warning the only outcome.
    for (final unusable in [
      (
        label: 'an unknown name',
        yaml: 'search:\n  providers:\n    brave:\n      enabled: true\n      credential: nope\n',
        stored: <String, CredentialEntry>{},
        reason: 'is not a configured credentials entry',
      ),
      (
        label: 'a github-token entry',
        yaml: braveCredential,
        stored: const {'brave-search': CredentialEntry.githubToken(token: 'ghp_x')},
        reason: 'is not an api_key credential',
      ),
      (
        label: 'an entry resolving blank',
        yaml: braveCredential,
        stored: const {'brave-search': CredentialEntry(apiKey: '')},
        reason: 'resolves to an empty value',
      ),
      (
        label: 'an entry resolving to whitespace',
        yaml: braveCredential,
        stored: const {'brave-search': CredentialEntry(apiKey: '   ')},
        reason: 'resolves to an empty value',
      ),
    ]) {
      test('${unusable.label} skips the provider with a named warning', () {
        registerStoredCredentials(unusable.stored);

        final config = loadYaml(unusable.yaml);
        expect(
          config.search.providers,
          isEmpty,
          reason: 'an unusable reference drops the provider rather than storing a blank key',
        );
        expect(config.warnings, anyElement(allOf(contains('search.providers.brave'), contains(unusable.reason))));
      });
    }

    test('a blank credential value is refused by name', () {
      final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: true\n      credential: "  "\n');
      expect(config.search.providers, isEmpty);
      expect(config.warnings, anyElement(contains('search.providers.brave')));
    });

    test('api_key and credential together warn and skip, with no silent precedence', () {
      registerStoredCredentials(const {'brave-search': CredentialEntry(apiKey: 'stored-brave-key')});

      final config = loadYaml(
        'search:\n  providers:\n    brave:\n      enabled: true\n'
        '      api_key: literal-key\n      credential: brave-search\n',
      );
      expect(config.search.providers, isEmpty);
      expect(
        config.warnings,
        anyElement(allOf(contains('search.providers.brave'), contains('api_key'), contains('credential'))),
      );
      expect(config.warnings.join('\n'), isNot(contains('literal-key')));
      expect(config.warnings.join('\n'), isNot(contains('stored-brave-key')));
    });

    test('api_key and credential are mutually exclusive even when either is null', () {
      registerStoredCredentials(const {'brave-search': CredentialEntry(apiKey: 'stored-brave-key')});
      for (final pair in [
        'api_key: null\n      credential: brave-search',
        'api_key: literal-key\n      credential: null',
      ]) {
        final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: true\n      $pair\n');

        expect(config.search.providers, isEmpty, reason: pair);
        expect(
          config.warnings,
          anyElement(allOf(contains('search.providers.brave'), contains('api_key'), contains('credential'))),
          reason: pair,
        );
      }
    });

    test('a non-string credential is refused rather than stringified', () {
      final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: true\n      credential: 42\n');
      expect(config.search.providers, isEmpty);
      expect(config.warnings, anyElement(contains('search.providers.brave')));
    });
  });
}
