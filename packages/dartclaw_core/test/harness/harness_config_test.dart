import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('HarnessConfig', () {
    test('default config produces empty initialize fields', () {
      const config = HarnessConfig();
      expect(config.toInitializeFields(), isEmpty);
    });

    test('toInitializeFields omits null and default fields', () {
      const config = HarnessConfig(maxTurns: 50);
      final fields = config.toInitializeFields();
      expect(fields, {'maxTurns': 50});
      expect(fields.containsKey('disallowedTools'), isFalse);
      expect(fields.containsKey('model'), isFalse);
      expect(fields.containsKey('agents'), isFalse);
      expect(fields.containsKey('context1m'), isFalse);
    });

    test('all fields included when set', () {
      final config = HarnessConfig(
        disallowedTools: ['Computer', 'Bash'],
        maxTurns: 25,
        model: 'claude-sonnet-4-6',
        agents: {'search': {'description': 'Search agent'}},
        context1m: true,
      );
      final fields = config.toInitializeFields();
      expect(fields['disallowedTools'], ['Computer', 'Bash']);
      expect(fields['maxTurns'], 25);
      expect(fields['model'], 'claude-sonnet-4-6');
      expect(fields['agents'], {'search': {'description': 'Search agent'}});
      expect(fields['context1m'], true);
    });

    test('empty disallowedTools list is omitted', () {
      const config = HarnessConfig(disallowedTools: []);
      expect(config.toInitializeFields().containsKey('disallowedTools'), isFalse);
    });

    test('context1m false is omitted', () {
      const config = HarnessConfig(context1m: false);
      expect(config.toInitializeFields().containsKey('context1m'), isFalse);
    });

    test('mcpServerUrl and mcpGatewayToken excluded from toInitializeFields', () {
      const config = HarnessConfig(
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
