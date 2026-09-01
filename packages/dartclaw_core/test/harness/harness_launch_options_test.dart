import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('HarnessLaunchOptions', () {
    test('default config produces empty initialize fields', () {
      const config = HarnessLaunchOptions();
      expect(config.toInitializeFields(), isEmpty);
    });

    test('toInitializeFields omits null and default fields', () {
      const config = HarnessLaunchOptions(maxTurns: 50);
      final fields = config.toInitializeFields();
      expect(fields, {'maxTurns': 50});
      expect(fields.containsKey('disallowedTools'), isFalse);
      expect(fields.containsKey('model'), isFalse);
    });

    test('all fields included when set', () {
      final config = HarnessLaunchOptions(disallowedTools: ['Computer', 'Bash'], maxTurns: 25, model: 'sonnet');
      final fields = config.toInitializeFields();
      expect(fields['disallowedTools'], ['Computer', 'Bash']);
      expect(fields['maxTurns'], 25);
      expect(fields['model'], 'sonnet');
    });

    test('empty disallowedTools list is omitted', () {
      const config = HarnessLaunchOptions(disallowedTools: []);
      expect(config.toInitializeFields().containsKey('disallowedTools'), isFalse);
    });

    test('mcpServerUrl and mcpGatewayToken excluded from toInitializeFields', () {
      const config = HarnessLaunchOptions(
        mcpServerUrl: 'http://127.0.0.1:3000/mcp',
        mcpGatewayToken: 'test-token',
        maxTurns: 10,
      );
      final fields = config.toInitializeFields();
      expect(fields.containsKey('mcpServerUrl'), isFalse);
      expect(fields.containsKey('mcpGatewayToken'), isFalse);
      // Other fields still present.
      expect(fields['maxTurns'], 10);
    });
  });
}
