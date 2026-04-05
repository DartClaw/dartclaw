import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

DartclawConfig _loadConfig(String yaml) => DartclawConfig.load(
  fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
  env: {'HOME': '/home/user'},
);

void main() {
  group('TaskBudgetConfig parsing', () {
    test('missing tasks.budget section uses defaults', () {
      const config = DartclawConfig.defaults();
      expect(config.tasks.budget.defaultMaxTokens, isNull);
      expect(config.tasks.budget.warningThreshold, 0.8);
    });

    test('parses default_max_tokens from YAML', () {
      final config = _loadConfig('''
tasks:
  budget:
    default_max_tokens: 100000
''');
      expect(config.tasks.budget.defaultMaxTokens, 100000);
      expect(config.tasks.budget.warningThreshold, 0.8);
    });

    test('parses warning_threshold from YAML', () {
      final config = _loadConfig('''
tasks:
  budget:
    warning_threshold: 0.9
''');
      expect(config.tasks.budget.warningThreshold, 0.9);
      expect(config.tasks.budget.defaultMaxTokens, isNull);
    });

    test('parses both budget fields together', () {
      final config = _loadConfig('''
tasks:
  budget:
    default_max_tokens: 50000
    warning_threshold: 0.75
''');
      expect(config.tasks.budget.defaultMaxTokens, 50000);
      expect(config.tasks.budget.warningThreshold, 0.75);
    });

    test('budget section does not affect other tasks fields', () {
      final config = _loadConfig('''
tasks:
  max_concurrent: 5
  budget:
    default_max_tokens: 200000
''');
      expect(config.tasks.maxConcurrent, 5);
      expect(config.tasks.budget.defaultMaxTokens, 200000);
    });

    test('partial budget section uses defaults for missing fields', () {
      final config = _loadConfig('''
tasks:
  budget:
    warning_threshold: 0.7
''');
      expect(config.tasks.budget.defaultMaxTokens, isNull);
      expect(config.tasks.budget.warningThreshold, 0.7);
    });

    test('invalid warning_threshold value emits warning and uses default', () {
      final config = _loadConfig('''
tasks:
  budget:
    warning_threshold: 2.5
''');
      expect(config.tasks.budget.warningThreshold, 0.8);
      expect(config.warnings, anyElement(contains('warning_threshold')));
    });

    test('invalid budget section type emits warning and uses default', () {
      final config = _loadConfig('''
tasks:
  budget: "not-a-map"
''');
      expect(config.tasks.budget.defaultMaxTokens, isNull);
      expect(config.warnings, anyElement(contains('tasks.budget')));
    });

    test('zero or negative default_max_tokens treated as no budget', () {
      final config = _loadConfig('''
tasks:
  budget:
    default_max_tokens: 0
''');
      expect(config.tasks.budget.defaultMaxTokens, isNull);
    });
  });
}
