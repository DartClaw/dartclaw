import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  test('accepts an explicit relevance model route', () {
    final config = loadYaml('search:\n  relevance_model: " Claude / sonnet "\n');

    expect(config.search.relevanceModel, 'claude/sonnet');
    expect(config.warnings, isEmpty);
  });

  test('accepts an explicit null relevance route as primary inheritance', () {
    final config = loadYaml('search:\n  relevance_model: null\n');

    expect(config.search.relevanceModel, isNull);
    expect(config.warnings, isEmpty);
  });

  test('refuses an invalid relevance route instead of falling back to the primary model', () {
    for (final value in ['sonnet', 'openai/gpt-5', 'claude/', 'claude/sonnet/extra', '   ']) {
      expect(
        () => loadYaml('search:\n  relevance_model: "$value"\n'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('provider/model'))),
        reason: value,
      );
    }
    expect(
      () => loadYaml('search:\n  relevance_model: 42\n'),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('provider/model string'))),
    );
  });

  group('search.embedding config', () {
    test('defaults to supported local embeddings and derives the retained vector path', () {
      final config = loadNoFile();

      expect(config.search.backend, 'fts5');
      expect(config.search.embedding, const EmbeddingConfig());
      expect(config.search.embedding.provider, EmbeddingProviderKind.local);
      expect(config.search.embedding.model, 'embeddinggemma-300M-Q8_0.gguf');
      expect(config.search.embedding.endpoint, isNull);
      expect(config.search.embedding.credential, isNull);
      expect(DartclawConfig(server: const ServerConfig(dataDir: '/data')).vectorsDbPath, '/data/vectors.db');
    });

    test('hybrid local accepts only the supported managed model selector', () {
      final configured = loadYaml(
        'search:\n  backend: hybrid\n  embedding:\n    provider: local\n'
        '    model: embeddinggemma-300M-Q8_0.gguf\n',
      );

      expect(configured.search.backend, 'hybrid');
      expect(configured.search.embedding, const EmbeddingConfig());
      expect(configured.warnings, isEmpty);

      final invalid = loadYaml(
        'search:\n  backend: hybrid\n  embedding:\n    provider: local\n'
        '    model: /tmp/arbitrary.gguf\n    endpoint: https://example.com/v1/embeddings\n'
        '    credential: remote-key\n',
      );
      expect(invalid.search.embedding, const EmbeddingConfig());
      expect(invalid.reloadBlockingWarnings, hasLength(3));
    });

    test(
      'HTTP preserves its endpoint, explicit model, and credential name without resolving the secret into config',
      () {
        registerStoredCredentials(const {'remote-key': CredentialEntry(apiKey: 'top-secret-api-key')});

        final config = loadYaml(
          'search:\n  backend: hybrid\n  embedding:\n    provider: http\n'
          '    model: text-embedding-v3\n    endpoint: https://embeddings.example/v1/embeddings\n'
          '    credential: remote-key\n',
        );

        expect(config.search.embedding.provider, EmbeddingProviderKind.http);
        expect(config.search.embedding.model, 'text-embedding-v3');
        expect(config.search.embedding.endpoint, Uri.parse('https://embeddings.example/v1/embeddings'));
        expect(config.search.embedding.credential, 'remote-key');
        expect(config.search.embedding.toString(), isNot(contains('top-secret-api-key')));
        expect(config.warnings, isEmpty);
      },
    );

    test('credentialed HTTP requires HTTPS except for literal loopback hosts', () {
      registerStoredCredentials(const {'remote-key': CredentialEntry(apiKey: 'top-secret-api-key')});

      final publicHttp = loadYaml(
        'search:\n  embedding:\n    provider: http\n    model: remote\n'
        '    endpoint: http://embeddings.example/v1/embeddings\n    credential: remote-key\n',
      );
      final output = publicHttp.warnings.join('\n');
      expect(publicHttp.search.embedding.endpoint, isNull);
      expect(publicHttp.search.embedding.credential, isNull);
      expect(output, contains('requires HTTPS'));
      expect(output, isNot(contains('http://embeddings.example/v1/embeddings')));
      expect(output, isNot(contains('top-secret-api-key')));

      final publicWithoutCredential = loadYaml(
        'search:\n  embedding:\n    provider: http\n    model: remote\n'
        '    endpoint: http://embeddings.example/v1/embeddings\n',
      );
      expect(publicWithoutCredential.search.embedding.endpoint, Uri.parse('http://embeddings.example/v1/embeddings'));
      expect(publicWithoutCredential.warnings, isEmpty);

      final httpsWithCredential = loadYaml(
        'search:\n  embedding:\n    provider: http\n    model: remote\n'
        '    endpoint: https://embeddings.example/v1/embeddings\n    credential: remote-key\n',
      );
      expect(httpsWithCredential.search.embedding.endpoint, Uri.parse('https://embeddings.example/v1/embeddings'));
      expect(httpsWithCredential.search.embedding.credential, 'remote-key');
      expect(httpsWithCredential.warnings, isEmpty);

      for (final host in ['localhost', '127.0.0.1', '[::1]']) {
        final loopback = loadYaml(
          'search:\n  embedding:\n    provider: http\n    model: remote\n'
          '    endpoint: http://$host/v1/embeddings\n    credential: remote-key\n',
        );
        expect(loopback.search.embedding.endpoint, Uri.parse('http://$host/v1/embeddings'), reason: host);
        expect(loopback.search.embedding.credential, 'remote-key', reason: host);
        expect(loopback.warnings, isEmpty, reason: host);
      }
    });

    test('HTTP requires endpoint and an explicitly present non-empty model', () {
      for (final yaml in [
        'search:\n  embedding:\n    provider: http\n    model: explicit\n',
        'search:\n  embedding:\n    provider: http\n    endpoint: https://example.com/v1/embeddings\n',
        'search:\n  embedding:\n    provider: http\n    model: "  "\n'
            '    endpoint: https://example.com/v1/embeddings\n',
      ]) {
        final config = loadYaml(yaml);

        expect(config.search.embedding.provider, EmbeddingProviderKind.http, reason: yaml);
        expect(config.search.embedding.model, isEmpty, reason: yaml);
        expect(config.search.embedding.endpoint, isNull, reason: yaml);
        expect(config.reloadBlockingWarnings, isNotEmpty, reason: yaml);
      }
    });

    test('unsafe HTTP endpoints are discarded and never echoed in validation output', () {
      const unsafeEndpoints = [
        'https://alice:uri-secret@example.com/v1/embeddings',
        'https://example.com/v1/embeddings?api_key=query-secret',
        'https://example.com/v1/embeddings#fragment-secret',
        'ftp://example.com/model',
        '/relative/embeddings',
      ];
      for (final endpoint in unsafeEndpoints) {
        final config = loadYaml(
          'search:\n  embedding:\n    provider: http\n    model: explicit\n    endpoint: "$endpoint"\n',
        );
        final output = config.warnings.join('\n');

        expect(config.search.embedding.endpoint, isNull, reason: endpoint);
        expect(output, contains('search.embedding.endpoint'), reason: endpoint);
        expect(output, isNot(contains(endpoint)), reason: endpoint);
        expect(output, isNot(anyOf(contains('uri-secret'), contains('query-secret'), contains('fragment-secret'))));
      }
    });

    test('HTTP credential must name a present generic API-key entry', () {
      for (final invalid in [
        (name: 'missing', entries: <String, CredentialEntry>{}),
        (name: 'wrong-kind', entries: const {'wrong-kind': CredentialEntry.githubToken(token: 'github-secret')}),
        (name: 'blank', entries: const {'blank': CredentialEntry(apiKey: '  ')}),
      ]) {
        registerStoredCredentials(invalid.entries);
        final config = loadYaml(
          'search:\n  embedding:\n    provider: http\n    model: explicit\n'
          '    endpoint: https://example.com/v1/embeddings\n    credential: ${invalid.name}\n',
        );
        final output = config.warnings.join('\n');

        expect(config.search.embedding.endpoint, isNull, reason: invalid.name);
        expect(config.search.embedding.credential, isNull, reason: invalid.name);
        expect(output, contains('search.embedding.credential'), reason: invalid.name);
        expect(
          output,
          isNot(anyOf(contains('github-secret'), contains(invalid.entries[invalid.name]?.secret ?? 'never'))),
        );
        DartclawConfig.clearStoredCredentialProvider();
      }
    });

    test('unknown provider values and embedding keys follow config refusal authorities', () {
      final invalidProvider = loadYaml('search:\n  embedding:\n    provider: automatic\n');
      expect(invalidProvider.search.embedding, const EmbeddingConfig());
      expect(invalidProvider.warnings, anyElement(contains('search.embedding.provider')));

      expect(
        () => loadYaml('search:\n  embedding:\n    provider: local\n    dimension: 768\n'),
        throwsA(
          isA<FormatException>().having((error) => error.message, 'message', contains('search.embedding.dimension')),
        ),
      );
    });

    test('value equality includes all embedding fields', () {
      final endpoint = Uri.parse('https://example.com/v1/embeddings');
      final first = SearchConfig(
        backend: 'hybrid',
        embedding: EmbeddingConfig(
          provider: EmbeddingProviderKind.http,
          model: 'remote',
          endpoint: endpoint,
          credential: 'remote-key',
        ),
      );
      final same = SearchConfig(
        backend: 'hybrid',
        embedding: EmbeddingConfig(
          provider: EmbeddingProviderKind.http,
          model: 'remote',
          endpoint: endpoint,
          credential: 'remote-key',
        ),
      );

      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first, isNot(const SearchConfig(backend: 'hybrid')));
      expect(
        first,
        isNot(SearchConfig(backend: 'hybrid', embedding: first.embedding, relevanceModel: 'claude/sonnet')),
      );
    });
  });

  group('search.qmd config', () {
    test('keeps QMD functional with exactly one non-blocking deprecation advisory', () {
      final config = loadYaml('search:\n  backend: qmd\n');

      expect(config.search.backend, 'qmd');
      expect(config.warnings.where((warning) => warning.toLowerCase().contains('deprecated')), hasLength(1));
      expect(config.reloadBlockingWarnings, isEmpty);
    });

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
