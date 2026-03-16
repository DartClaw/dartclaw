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

      test('non-search agent with no tools gets empty allowedTools and warning', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('summarizer', {'prompt': 'Summarize this'}, warns);
        expect(agent.allowedTools, isEmpty);
        expect(warns, hasLength(1));
        expect(warns.first, contains('summarizer'));
        expect(warns.first, contains('no tools'));
      });

      test('search agent with no tools gets WebSearch and WebFetch defaults', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {'prompt': 'Search the web'}, warns);
        expect(agent.allowedTools, equals({'WebSearch', 'WebFetch'}));
        expect(warns, isEmpty);
      });

      test('non-search agent with explicit tools keeps them without warning', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('custom', {
          'prompt': 'Do work',
          'tools': ['Bash', 'Read'],
        }, warns);
        expect(agent.allowedTools, equals({'Bash', 'Read'}));
        expect(warns, isEmpty);
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
