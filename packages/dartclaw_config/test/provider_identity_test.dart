import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderIdentity', () {
    test('falls back to claude for blank values', () {
      expect(ProviderIdentity.normalize(''), 'claude');
      expect(ProviderIdentity.family(null), 'claude');
      expect(ProviderIdentity.displayName('   '), 'Claude');
    });
  });
}
