import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('AgentDefinition', () {
    group('searchAgent factory', () {
      test('defaults model to claude-haiku-4-5', () {
        final agent = AgentDefinition.searchAgent();
        expect(agent.model, 'claude-haiku-4-5');
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
      test('parses model field', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {
          'model': 'claude-haiku-4-5',
          'description': 'Test agent',
        }, warns);
        expect(agent.model, 'claude-haiku-4-5');
        expect(warns, isEmpty);
      });

      test('model is null when not specified', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {
          'description': 'Test agent',
        }, warns);
        expect(agent.model, isNull);
      });

      test('model does not leak into extra', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {
          'model': 'claude-haiku-4-5',
          'custom_key': 'custom_value',
        }, warns);
        expect(agent.model, 'claude-haiku-4-5');
        expect(agent.extra, isNot(contains('model')));
        expect(agent.extra['custom_key'], 'custom_value');
      });
    });

    group('toInitializePayload', () {
      test('includes model when non-null', () {
        final agent = AgentDefinition.searchAgent();
        final payload = agent.toInitializePayload();
        expect(payload['model'], 'claude-haiku-4-5');
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

    group('constructor', () {
      test('model defaults to null', () {
        const agent = AgentDefinition(
          id: 'test',
          description: 'Test',
          prompt: 'Test prompt',
        );
        expect(agent.model, isNull);
      });

      test('accepts explicit model', () {
        const agent = AgentDefinition(
          id: 'test',
          description: 'Test',
          prompt: 'Test prompt',
          model: 'claude-sonnet-4-6',
        );
        expect(agent.model, 'claude-sonnet-4-6');
      });
    });
  });
}
