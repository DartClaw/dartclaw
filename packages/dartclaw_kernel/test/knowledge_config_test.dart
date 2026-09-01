import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('knowledge jobs default to disabled', () {
    const config = DartclawConfig.defaults();

    expect(config.knowledge.inbox.enabled, isFalse);
    expect(config.knowledge.inbox.effort, 'medium');
    expect(config.knowledge.wikiLint.enabled, isFalse);
  });

  test('blank inbox effort falls back to the default', () {
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml' ? 'knowledge:\n  inbox:\n    effort: "   "\n' : null,
    );

    expect(config.knowledge.inbox.effort, 'medium');
  });

  test('parses typed knowledge scheduler config', () {
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? '''
knowledge:
  inbox:
    enabled: true
    interval_minutes: 15
    max_bytes: 2048
    retry_attempts: 4
    processed_retention_days: 9
    delivery_mode: none
    effort: high
  wiki_lint:
    enabled: true
    interval_minutes: 90
    delivery_mode: webhook
'''
          : null,
    );

    expect(config.knowledge.inbox.enabled, isTrue);
    expect(config.knowledge.inbox.intervalMinutes, 15);
    expect(config.knowledge.inbox.maxBytes, 2048);
    expect(config.knowledge.inbox.retryAttempts, 4);
    expect(config.knowledge.inbox.processedRetentionDays, 9);
    expect(config.knowledge.inbox.deliveryMode, 'none');
    expect(config.knowledge.inbox.effort, 'high');
    expect(config.knowledge.wikiLint.enabled, isTrue);
    expect(config.knowledge.wikiLint.intervalMinutes, 90);
    expect(config.knowledge.wikiLint.deliveryMode, 'webhook');
  });

  test('an out-of-range knowledge value still clamps silently, exactly as before the bounds were declared', () {
    // The declared max is a write-path bound only: the clamps stay where they
    // are, stay silent, and a file that boots today boots to the same values.
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? '''
knowledge:
  inbox:
    interval_minutes: 5000
    max_bytes: 999999999
    retry_attempts: 99
    processed_retention_days: 4000
  wiki_lint:
    interval_minutes: 5000
'''
          : null,
    );

    expect(config.knowledge.inbox.intervalMinutes, 1440);
    expect(config.knowledge.inbox.maxBytes, 52428800);
    expect(config.knowledge.inbox.retryAttempts, 10);
    expect(config.knowledge.inbox.processedRetentionDays, 3650);
    expect(config.knowledge.wikiLint.intervalMinutes, 1440);
    // A clamp emits nothing today and must keep emitting nothing: no running
    // instance gains a boot advisory from a declaration change.
    expect(config.warnings.where((warning) => warning.contains('knowledge.')), isEmpty);
  });

  test('all five declared maxima saturate silently at their exact bounds', () {
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? '''
knowledge:
  inbox:
    interval_minutes: 5000
    max_bytes: 999999999
    retry_attempts: 99
    processed_retention_days: 99999
  wiki_lint:
    interval_minutes: 5000
'''
          : null,
    );

    expect(config.knowledge.inbox.intervalMinutes, 1440);
    expect(config.knowledge.inbox.maxBytes, 52428800);
    expect(config.knowledge.inbox.retryAttempts, 10);
    expect(config.knowledge.inbox.processedRetentionDays, 3650);
    expect(config.knowledge.wikiLint.intervalMinutes, 1440);
    expect(config.warnings.where((warning) => warning.contains('knowledge.')), isEmpty);
  });
}
