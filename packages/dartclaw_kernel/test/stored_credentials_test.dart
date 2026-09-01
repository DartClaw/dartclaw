import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('stored credentials merge into the loaded config', () {
    test('with no provider registered, credentials parse exactly as before', () {
      final config = loadYaml('credentials:\n  github-main:\n    type: github-token\n    token: from-yaml\n');
      expect(config.credentials['github-main']?.secret, 'from-yaml');
      expect(config.warnings, isEmpty);
    });

    test('a stored entry needs no credentials: block in YAML', () {
      registerStoredCredentials(const {'brave-search': CredentialEntry(apiKey: 'stored-value')});

      final config = loadNoFile();
      expect(config.credentials['brave-search']?.secret, 'stored-value');
      expect(config.credentials['brave-search']?.type, CredentialType.apiKey);
    });

    test('the store wins over a config-declared entry of the same name', () {
      registerStoredCredentials(const {'github-main': CredentialEntry.githubToken(token: 'from-store')});

      final config = loadYaml('credentials:\n  github-main:\n    type: github-token\n    token: from-yaml\n');
      expect(config.credentials['github-main']?.secret, 'from-store');
    });

    test('config-only names survive the merge alongside stored ones', () {
      registerStoredCredentials(const {'stored': CredentialEntry(apiKey: 'a')});

      final config = loadYaml('credentials:\n  declared:\n    api_key: b\n');
      expect(config.credentials.entries.keys, unorderedEquals(['stored', 'declared']));
    });

    test('the provider is invoked on every load, with the credentials directory of that load', () {
      final invocations = <String>[];
      registerStoredCredentials(const {}, onInvoke: invocations.add);

      final first = loadYaml('data_dir: /srv/one\n');
      final second = loadYaml('data_dir: /srv/two\n');

      expect(invocations, [first.credentialsDir, second.credentialsDir]);
      expect(invocations, ['/srv/one/credentials', '/srv/two/credentials']);
    });

    test('a provider that throws leaves the config loadable on its declared entries', () {
      DartclawConfig.registerStoredCredentialProvider((_) => throw StateError('unusable store'));
      addTearDown(DartclawConfig.clearStoredCredentialProvider);

      final config = loadYaml('credentials:\n  declared:\n    api_key: b\n');
      expect(config.credentials['declared']?.secret, 'b');
      expect(config.warnings, anyElement(contains('stored credentials')));
    });

    // OC03's "no secret reaches a log line" for the path this story adds: the
    // merge is what puts a stored value into config parsing.
    test('merging a stored credential emits no log record and no warning carrying the value', () {
      const secret = 'STORED-SECRET-VALUE-XYZ';
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      registerStoredCredentials(const {'brave-search': CredentialEntry(apiKey: secret)});

      final config = loadYaml(
        'search:\n  providers:\n    brave:\n      enabled: true\n      credential: brave-search\n',
      );

      expect(config.credentials['brave-search']?.secret, secret, reason: 'the value did reach the config');
      final emitted = [...records.map((record) => record.message), ...config.warnings].join('\n');
      for (var start = 0; start + 6 <= secret.length; start++) {
        expect(emitted, isNot(contains(secret.substring(start, start + 6))));
      }
    });

    test('clearing the provider restores the unregistered behavior', () {
      registerStoredCredentials(const {'stored': CredentialEntry(apiKey: 'a')});
      DartclawConfig.clearStoredCredentialProvider();
      expect(loadNoFile().credentials['stored'], isNull);
    });
  });
}
