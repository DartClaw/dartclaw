import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderIdentity', () {
    test('falls back to claude for blank values', () {
      expect(ProviderIdentity.normalize(''), 'claude');
      expect(ProviderIdentity.family(null), 'claude');
      expect(ProviderIdentity.displayName('   '), 'Claude');
    });

    test('parses provider/model shorthand for known providers', () {
      expect(ProviderIdentity.parseProviderModelShorthand('claude/opus'), (provider: 'claude', model: 'opus'));
      expect(ProviderIdentity.parseProviderModelShorthand(' codex / gpt-5.4-mini '), (
        provider: 'codex',
        model: 'gpt-5.4-mini',
      ));
    });

    test('returns null for non-shorthand or unknown provider prefixes', () {
      expect(ProviderIdentity.parseProviderModelShorthand('opus'), isNull);
      expect(ProviderIdentity.parseProviderModelShorthand('openai/gpt-5.4'), isNull);
      expect(ProviderIdentity.parseProviderModelShorthand('claude/opus/extra'), isNull);
    });
  });
}
