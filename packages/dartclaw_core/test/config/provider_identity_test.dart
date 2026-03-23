import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderIdentity', () {
    test('normalizes codex-exec into codex family', () {
      expect(ProviderIdentity.family('codex-exec'), 'codex');
      expect(ProviderIdentity.displayName('codex-exec'), 'Codex');
    });

    test('falls back to claude for blank values', () {
      expect(ProviderIdentity.normalize(''), 'claude');
      expect(ProviderIdentity.family(null), 'claude');
      expect(ProviderIdentity.displayName('   '), 'Claude');
    });
  });
}
