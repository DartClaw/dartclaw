import 'package:dartclaw_config/dartclaw_config.dart';
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
}
