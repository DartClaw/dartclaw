import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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

    test('normalizes map keys and rejects blank or colliding IDs', () {
      expect(ProviderIdentity.normalizeKeys({' Codex ': 1}), {'codex': 1});
      expect(() => ProviderIdentity.normalizeKeys({' ': 1}), throwsStateError);
      expect(() => ProviderIdentity.normalizeKeys({'Codex': 1, ' codex ': 2}), throwsStateError);
    });
  });
}
