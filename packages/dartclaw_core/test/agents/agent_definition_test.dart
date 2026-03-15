import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('AgentDefinition', () {
    group('searchAgent factory', () {
      test('defaults model to haiku shorthand', () {
        final agent = AgentDefinition.searchAgent();
        expect(agent.model, 'haiku');
      });

      test('allows model override', () {
        final agent = AgentDefinition.searchAgent(model: 'custom-model');
        expect(agent.model, 'custom-model');
      });

      test('sets expected defaults', () {
        final agent = AgentDefinition.searchAgent();
        expect(agent.id, 'search');
        expect(agent.allowedTools, containsAll(['WebSearch', 'WebFetch']));
        expect(agent.maxConcurrent, 2);
      });
    });

    group('fromYaml', () {
      test('parses model field and keeps extra keys out of model', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {
          'model': 'haiku',
          'custom_key': 'custom_value',
        }, warns);
        expect(agent.model, 'haiku');
        expect(agent.extra, isNot(contains('model')));
        expect(agent.extra['custom_key'], 'custom_value');
        expect(warns, isEmpty);
      });

      test('model is null when not specified', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {
          'description': 'Test agent',
        }, warns);
        expect(agent.model, isNull);
      });
    });

    group('toInitializePayload', () {
      test('includes model when non-null', () {
        final agent = AgentDefinition.searchAgent();
        final payload = agent.toInitializePayload();
        expect(payload['model'], 'haiku');
      });

      test('excludes model when null', () {
        const agent = AgentDefinition(
          id: 'test',
          description: 'Test',
          prompt: 'Test prompt',
        );
        final payload = agent.toInitializePayload();
        expect(payload.containsKey('model'), isFalse);
      });

      test('includes description and prompt', () {
        final agent = AgentDefinition.searchAgent();
        final payload = agent.toInitializePayload();
        expect(payload['description'], isNotEmpty);
        expect(payload['prompt'], isNotEmpty);
      });
    });
  });
}
