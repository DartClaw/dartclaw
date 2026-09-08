import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('HarnessLaunchOptions', () {
    test('copyWith replaces only the named fields', () {
      const base = HarnessLaunchOptions(disallowedTools: ['Computer'], maxTurns: 25, model: 'sonnet');
      final copy = base.copyWith(disallowedTools: ['Bash']);

      expect(copy.disallowedTools, ['Bash']);
      expect(copy.maxTurns, 25);
      expect(copy.model, 'sonnet');
      expect(base.disallowedTools, ['Computer']);
    });
  });
}
