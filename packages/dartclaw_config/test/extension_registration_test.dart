import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('extension registration', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    // TC-E01: registered parser is called and result is accessible
    test('registered parser is invoked and result accessible via extension<T>()', () {
      DartclawConfig.registerExtensionParser(
        'slack',
        (yaml, warns) => _SlackConfig(webhook: yaml['webhook'] as String? ?? ''),
      );
      final config = loadYaml('slack:\n  webhook: https://hooks.example.com/abc\n');
      expect(config.warnings, isEmpty);
      final slack = config.extension<_SlackConfig>('slack');
      expect(slack.webhook, 'https://hooks.example.com/abc');
    });

    // TC-E02: unknown key without parser produces warning and stores raw map
    test('unknown key without parser produces warning and stores raw map', () {
      final config = loadYaml('my_custom_section:\n  foo: bar\n');
      expect(config.warnings, anyElement(contains('Unknown config key: my_custom_section')));
      final raw = config.extensions['my_custom_section'];
      expect(raw, isA<Map<String, dynamic>>());
      expect((raw as Map<String, dynamic>)['foo'], 'bar');
    });

    // TC-E03: extension<T>() throws StateError for missing key
    test('extension<T>() throws StateError when key not present', () {
      final config = const DartclawConfig.defaults();
      expect(() => config.extension<_SlackConfig>('slack'), throwsStateError);
    });

    // TC-E04: extension<T>() throws ArgumentError for wrong type
    test('extension<T>() throws ArgumentError for type mismatch', () {
      final config = DartclawConfig(extensions: {'slack': _SlackConfig(webhook: 'x')});
      expect(() => config.extension<String>('slack'), throwsArgumentError);
    });

    // TC-E05: registerExtensionParser throws for built-in key
    test('registerExtensionParser throws ArgumentError for built-in key', () {
      expect(() => DartclawConfig.registerExtensionParser('agent', (a, b) => {}), throwsArgumentError);
    });

    // TC-E06: parser throwing stores raw map and adds warning
    test('parser exception falls back to raw map and warns', () {
      DartclawConfig.registerExtensionParser('bad_ext', (yaml, warns) {
        throw Exception('parse failed');
      });
      final config = loadYaml('bad_ext:\n  x: 1\n');
      expect(config.warnings, anyElement(contains('Error parsing extension "bad_ext"')));
      final raw = config.extensions['bad_ext'];
      expect(raw, isA<Map<String, dynamic>>());
    });

    // TC-E07: empty YAML section produces empty map for registered parser
    test('empty YAML section passes empty map to parser', () {
      final captured = <String, dynamic>{};
      DartclawConfig.registerExtensionParser('empty_ext', (yaml, warns) {
        captured.addAll(yaml);
        return _SlackConfig(webhook: '');
      });
      final config = loadYaml('empty_ext:\n');
      expect(config.warnings, isEmpty);
      expect(captured, isEmpty);
      expect(config.extension<_SlackConfig>('empty_ext').webhook, '');
    });

    // TC-E08: multiple extensions are all parsed independently
    test('multiple extensions are all parsed and retrievable', () {
      DartclawConfig.registerExtensionParser(
        'ext_a',
        (yaml, warns) => _SlackConfig(webhook: yaml['url'] as String? ?? ''),
      );
      DartclawConfig.registerExtensionParser(
        'ext_b',
        (yaml, warns) => _SlackConfig(webhook: yaml['endpoint'] as String? ?? ''),
      );
      final config = loadYaml('ext_a:\n  url: http://a\next_b:\n  endpoint: http://b\n');
      expect(config.extension<_SlackConfig>('ext_a').webhook, 'http://a');
      expect(config.extension<_SlackConfig>('ext_b').webhook, 'http://b');
    });

    // TC-E10: scalar extension value preserved losslessly (no coercion to {})
    test('scalar extension value is preserved losslessly', () {
      final config = loadYaml('feature_flag: true\n');
      expect(config.extensions['feature_flag'], isTrue);
      expect(config.warnings, anyElement(contains('Unknown config key: feature_flag')));
    });

    // TC-E11: list extension value preserved losslessly
    test('list extension value is preserved losslessly', () {
      final config = loadYaml('custom_list:\n  - alpha\n  - beta\n');
      final raw = config.extensions['custom_list'];
      expect(raw, isA<List<dynamic>>());
      expect(raw as List<dynamic>, ['alpha', 'beta']);
    });

    // TC-E12: null extension value preserved losslessly
    test('null extension value is preserved losslessly', () {
      final config = loadYaml('placeholder_section:\n');
      expect(config.extensions.containsKey('placeholder_section'), isTrue);
      expect(config.extensions['placeholder_section'], isNull);
    });

    // TC-E13: registered parser with non-map value warns and stores raw
    test('registered parser with non-map value warns and preserves raw', () {
      DartclawConfig.registerExtensionParser('flag_ext', (yaml, warns) => _SlackConfig(webhook: 'parsed'));
      final config = loadYaml('flag_ext: 42\n');
      expect(config.warnings, anyElement(contains('Extension "flag_ext" expected a map')));
      // Raw scalar preserved, parser was NOT invoked
      expect(config.extensions['flag_ext'], 42);
    });

    // TC-E14: extension<T>() works with null values (distinguishes missing vs null)
    test('extension<T>() distinguishes missing key from null value', () {
      final config = DartclawConfig(extensions: {'present_null': null});
      // Missing key → StateError
      expect(() => config.extension<Object?>('absent'), throwsStateError);
      // Present null key → returns null (not StateError)
      expect(config.extension<Object?>('present_null'), isNull);
    });

    // TC-E09: clearExtensionParsers resets registry so subsequent load ignores parser
    test('clearExtensionParsers removes all registered parsers', () {
      DartclawConfig.registerExtensionParser('gone', (yaml, warns) => _SlackConfig(webhook: 'x'));
      DartclawConfig.clearExtensionParsers();
      final config = loadYaml('gone:\n  x: 1\n');
      // With no parser, the unknown key should warn and be stored as raw map
      expect(config.warnings, anyElement(contains('Unknown config key: gone')));
      expect(config.extensions['gone'], isA<Map<String, dynamic>>());
    });
  });
}

class _SlackConfig {
  final String webhook;
  const _SlackConfig({required this.webhook});
}
