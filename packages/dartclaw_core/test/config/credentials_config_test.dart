import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

DartclawConfig _loadYaml(String yaml, {Map<String, String>? env}) {
  return DartclawConfig.load(
    configPath: 'dartclaw.yaml',
    fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
    env: {'HOME': '/tmp', ...?env},
  );
}

void main() {
  group('CredentialsConfig', () {
    test('value objects support equality and presence checks', () {
      const entry = CredentialEntry(apiKey: 'secret');
      const same = CredentialEntry(apiKey: 'secret');
      const config = CredentialsConfig(entries: {'anthropic': entry});

      expect(entry, equals(same));
      expect(entry.isPresent, isTrue);
      expect(config['anthropic'], entry);
      expect(config.toString(), contains('anthropic'));
    });

    test('parses credentials section with env var references', () {
      final config = _loadYaml(
        '''
credentials:
  anthropic:
    api_key: \${ANTHROPIC_API_KEY}
  openai:
    api_key: \${OPENAI_API_KEY}
''',
        env: {'ANTHROPIC_API_KEY': 'anthropic-test-key', 'OPENAI_API_KEY': 'openai-test-key'},
      );

      expect(config.credentials['anthropic']?.apiKey, 'anthropic-test-key');
      expect(config.credentials['openai']?.apiKey, 'openai-test-key');
    });

    test('unresolved env var resolves to empty string and logs warning', () async {
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = previousLevel;
        await subscription.cancel();
      });

      final config = _loadYaml('''
credentials:
  anthropic:
    api_key: \${ANTHROPIC_API_KEY}
''');

      await Future<void>.delayed(Duration.zero);

      expect(config.credentials['anthropic']?.apiKey, isEmpty);
      expect(
        records.any((record) => record.loggerName == 'envSubstitute' && record.message.contains('Undefined env var')),
        isTrue,
      );
    });

    test('returns empty CredentialsConfig when section absent', () {
      final config = _loadYaml('agent:\n  model: sonnet\n');

      expect(config.credentials, const CredentialsConfig.defaults());
      expect(config.credentials.isEmpty, isTrue);
    });

    test('handles literal API key values', () {
      final config = _loadYaml('''
credentials:
  openai:
    api_key: literal-api-key
''');

      expect(config.credentials['openai']?.apiKey, 'literal-api-key');
    });

    test('handles missing api_key field in credential entry', () {
      final config = _loadYaml('''
credentials:
  anthropic:
    token: nope
''');

      expect(config.credentials.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('credentials.anthropic missing "api_key"')));
    });

    test('handles invalid type for credentials section', () {
      final config = _loadYaml('credentials: nope\n');

      expect(config.credentials.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('Invalid type for credentials')));
    });
  });
}
