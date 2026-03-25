import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('AdvisorConfig', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    test('defaults are applied when advisor section is absent', () {
      final config = DartclawConfig.load(
        fileReader: (path) => path == 'dartclaw.yaml' ? '' : null,
        env: const {'HOME': '/home/user'},
      );

      expect(config.advisor, const AdvisorConfig.defaults());
    });

    test('advisor section parses correctly', () {
      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
advisor:
  enabled: true
  model: sonnet
  effort: high
  triggers:
    - periodic
    - explicit
  periodic_interval_minutes: 15
  max_window_turns: 20
  max_prior_reflections: 4
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.advisor.enabled, isTrue);
      expect(config.advisor.model, 'sonnet');
      expect(config.advisor.effort, 'high');
      expect(config.advisor.triggers, ['periodic', 'explicit']);
      expect(config.advisor.periodicIntervalMinutes, 15);
      expect(config.advisor.maxWindowTurns, 20);
      expect(config.advisor.maxPriorReflections, 4);
    });

    test('invalid trigger names are warned and skipped', () {
      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
advisor:
  triggers:
    - explicit
    - bad_trigger
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.advisor.triggers, ['explicit']);
      expect(config.warnings, contains(contains('Unknown advisor trigger: "bad_trigger"')));
    });

    test('unrecognized advisor model and effort produce warnings', () {
      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
advisor:
  model: mystery-model
  effort: turbo
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.advisor.model, 'mystery-model');
      expect(config.advisor.effort, 'turbo');
      expect(config.warnings, anyElement(contains('Unrecognized advisor.model')));
      expect(config.warnings, anyElement(contains('Unrecognized advisor.effort')));
    });

    test('registerExtensionParser rejects advisor as built-in key', () {
      expect(() => DartclawConfig.registerExtensionParser('advisor', (yaml, warns) => yaml), throwsArgumentError);
    });
  });
}
