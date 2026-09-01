import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('harness section retention', () {
    test('a harness.acp block survives a load as a raw section this package never parses', () {
      final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp"]
''');

      expect(config.harness.sections.keys, ['acp']);
      expect((config.harness.sections['acp']!['agents'] as Map)['goose'], containsPair('binary', 'goose'));
      // Retention is not a parse: nothing here validates the section, so a load
      // that is never primed by the owning package raises no ACP warning.
      expect(config.warnings.where((warning) => warning.contains('acp')), isEmpty);
    });

    test('a non-map harness sub-section is skipped with a warning rather than retained', () {
      final config = loadYaml('''
harness:
  acp: "not-a-map"
''');

      expect(config.harness.sections, isEmpty);
      expect(config.warnings, contains(contains('Invalid type for harness.acp')));
    });

    test('a config with no harness key at all retains nothing and refuses nothing', () {
      final config = loadYaml('agent:\n  model: sonnet\n');

      expect(config.harness.sections, isEmpty);
      expect(() => config.harness.assertSectionsHandled(const {}), returnsNormally);
    });

    test('assertSectionsHandled refuses a populated section no composed parser claims', () {
      final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
''');

      expect(
        () => config.harness.assertSectionsHandled(const {}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('harness.acp'), contains('No parser was composed')),
          ),
        ),
      );
      expect(() => config.harness.assertSectionsHandled(const {'acp'}), returnsNormally);
    });

    test('every unclaimed section is named, in one refusal', () {
      const harness = HarnessConfig(
        sections: {
          'acp': {'agents': <String, dynamic>{}},
          'zeta': <String, dynamic>{},
        },
      );

      expect(
        () => harness.assertSectionsHandled(const {}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('harness.acp'), contains('harness.zeta')),
          ),
        ),
      );
    });
  });
}
