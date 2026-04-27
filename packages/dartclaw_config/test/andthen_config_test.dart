import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('AndthenConfig', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    test('defaults are applied when andthen section is absent', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml' ? '' : null,
        env: const {'HOME': '/home/user'},
      );

      expect(config.andthen, const AndthenConfig.defaults());
      expect(config.andthen.gitUrl, 'https://github.com/IT-HUSET/andthen');
      expect(config.andthen.ref, 'latest');
      expect(config.andthen.installScope, AndthenInstallScope.dataDir);
      expect(config.andthen.network, AndthenNetworkPolicy.auto);
    });

    test('defaults round-trip through toJson/fromJson', () {
      const original = AndthenConfig.defaults();
      final round = AndthenConfig.fromJson(original.toJson());
      expect(round, original);
    });

    test('explicit YAML values for all four keys parse to the right shape', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
andthen:
  git_url: https://example.com/forks/andthen
  ref: v0.15.2
  install_scope: both
  network: required
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.andthen.gitUrl, 'https://example.com/forks/andthen');
      expect(config.andthen.ref, 'v0.15.2');
      expect(config.andthen.installScope, AndthenInstallScope.both);
      expect(config.andthen.network, AndthenNetworkPolicy.required);
    });

    test('install_scope: bogus warns and falls back to dataDir', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
andthen:
  install_scope: bogus
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.andthen.installScope, AndthenInstallScope.dataDir);
      expect(config.warnings, anyElement(contains('Invalid andthen.install_scope: "bogus"')));
    });

    test('network: bogus warns and falls back to auto', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
andthen:
  network: kinda
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.andthen.network, AndthenNetworkPolicy.auto);
      expect(config.warnings, anyElement(contains('Invalid andthen.network: "kinda"')));
    });

    test('unknown andthen key emits a warning but does not error', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
andthen:
  ref: main
  pony: true
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.andthen.ref, 'main');
      expect(config.warnings, anyElement(contains('Unknown andthen config key: "pony"')));
    });

    test('all four keys appear in ConfigNotifier.nonReloadableKeys', () {
      expect(
        ConfigNotifier.nonReloadableKeys,
        containsAll(<String>['andthen.git_url', 'andthen.ref', 'andthen.install_scope', 'andthen.network']),
      );
    });

    test('install_scope yamlValue strings are stable', () {
      expect(AndthenInstallScope.dataDir.yamlValue, 'data_dir');
      expect(AndthenInstallScope.user.yamlValue, 'user');
      expect(AndthenInstallScope.both.yamlValue, 'both');
    });

    test('network yamlValue strings are stable', () {
      expect(AndthenNetworkPolicy.auto.yamlValue, 'auto');
      expect(AndthenNetworkPolicy.required.yamlValue, 'required');
      expect(AndthenNetworkPolicy.disabled.yamlValue, 'disabled');
    });

    test('config_meta exposes all four keys', () {
      expect(ConfigMeta.fields.containsKey('andthen.git_url'), isTrue);
      expect(ConfigMeta.fields.containsKey('andthen.ref'), isTrue);
      expect(ConfigMeta.fields.containsKey('andthen.install_scope'), isTrue);
      expect(ConfigMeta.fields.containsKey('andthen.network'), isTrue);
      // All restart-mutability.
      for (final k in const ['andthen.git_url', 'andthen.ref', 'andthen.install_scope', 'andthen.network']) {
        expect(ConfigMeta.fields[k]!.mutability, ConfigMutability.restart);
      }
    });
  });
}
