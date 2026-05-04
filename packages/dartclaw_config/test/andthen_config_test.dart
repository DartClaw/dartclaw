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
      expect(config.andthen.network, AndthenNetworkPolicy.auto);
    });

    test('defaults round-trip through toJson/fromJson', () {
      const original = AndthenConfig.defaults();
      final round = AndthenConfig.fromJson(original.toJson());
      expect(round, original);
    });

    test('explicit YAML values parse to the right shape', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
andthen:
  git_url: https://example.com/forks/andthen
  ref: v0.15.2
  network: required
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.andthen.gitUrl, 'https://example.com/forks/andthen');
      expect(config.andthen.ref, 'v0.15.2');
      expect(config.andthen.network, AndthenNetworkPolicy.required);
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

    test('install_scope emits deprecation warning and is not parsed', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
andthen:
  ref: main
  install_scope: data_dir
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.andthen.ref, 'main');
      expect(
        config.warnings,
        anyElement(contains('andthen.install_scope is no longer supported')),
      );
      // Must not be reported as an unknown key — that would be a regression in
      // the deprecation branch's fall-through guard.
      expect(
        config.warnings,
        isNot(anyElement(contains('Unknown andthen config key: "install_scope"'))),
      );
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

    test('all keys appear in ConfigNotifier.nonReloadableKeys', () {
      expect(
        ConfigNotifier.nonReloadableKeys,
        containsAll(<String>['andthen.git_url', 'andthen.ref', 'andthen.network']),
      );
    });

    test('network yamlValue strings are stable', () {
      expect(AndthenNetworkPolicy.auto.yamlValue, 'auto');
      expect(AndthenNetworkPolicy.required.yamlValue, 'required');
      expect(AndthenNetworkPolicy.disabled.yamlValue, 'disabled');
    });

    test('config_meta exposes all keys', () {
      expect(ConfigMeta.fields.containsKey('andthen.git_url'), isTrue);
      expect(ConfigMeta.fields.containsKey('andthen.ref'), isTrue);
      expect(ConfigMeta.fields.containsKey('andthen.network'), isTrue);
      // All restart-mutability.
      for (final k in const ['andthen.git_url', 'andthen.ref', 'andthen.network']) {
        expect(ConfigMeta.fields[k]!.mutability, ConfigMutability.restart);
      }
    });
  });
}
