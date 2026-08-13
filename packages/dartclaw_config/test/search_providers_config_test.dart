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

    test('provider missing api_key skipped with warning', () {
      final config = loadYaml('search:\n  providers:\n    brave:\n      enabled: true\n');
      expect(config.search.providers, isEmpty);
      expect(config.warnings, anyElement(contains('missing "api_key"')));
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
}
