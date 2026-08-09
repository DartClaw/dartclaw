import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('AgentDefinition', () {
    group('searchAgent factory', () {
      test('leaves the search model provider-neutral', () {
        final agent = AgentDefinition.searchAgent();
        expect(agent.model, isNull);
      });

      test('allows model override', () {
        final agent = AgentDefinition.searchAgent(model: 'custom-model');
        expect(agent.model, 'custom-model');
      });

      test('sets expected defaults', () {
        final agent = AgentDefinition.searchAgent();
        expect(agent.id, 'search');
        expect(agent.allowedTools, containsAll(['web_search', 'web_fetch']));
        expect(agent.maxConcurrent, 2);
      });
    });

    group('fromYaml', () {
      test('parses model field and keeps extra keys out of model', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {'model': 'haiku', 'custom_key': 'custom_value'}, warns);
        expect(agent.model, 'haiku');
        expect(agent.extra, isNot(contains('model')));
        expect(agent.extra['custom_key'], 'custom_value');
        expect(warns, isEmpty);
      });

      test('model is null when not specified', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {'description': 'Test agent'}, warns);
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

      test('search agent with no tools gets canonical search defaults', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {'prompt': 'Search the web'}, warns);
        expect(agent.allowedTools, equals({'web_search', 'web_fetch'}));
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

      test('retired spawn fields warn and never leak into extra or payload', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {'max_spawn_depth': 2, 'max_children_per_agent': 5}, warns);

        expect(warns, contains('agents.search.max_spawn_depth is not enforced – ignored'));
        expect(warns, contains('agents.search.max_children_per_agent is not enforced – ignored'));
        expect(agent.extra, isNot(contains('max_spawn_depth')));
        expect(agent.extra, isNot(contains('max_children_per_agent')));
        expect(agent.toInitializePayload(), isNot(contains('max_spawn_depth')));
        expect(agent.toInitializePayload(), isNot(contains('max_children_per_agent')));
      });
    });

    group('toInitializePayload', () {
      test('includes model when non-null', () {
        final agent = AgentDefinition.searchAgent();
        final payload = agent.toInitializePayload();
        expect(payload.containsKey('model'), isFalse);
      });

      test('excludes model when null', () {
        const agent = AgentDefinition(id: 'test', description: 'Test', prompt: 'Test prompt');
        final payload = agent.toInitializePayload();
        expect(payload.containsKey('model'), isFalse);
      });

      test('includes description and prompt', () {
        final agent = AgentDefinition.searchAgent();
        final payload = agent.toInitializePayload();
        expect(payload['description'], isNotEmpty);
        expect(payload['prompt'], isNotEmpty);
      });

      test('includes tools exactly when the allowlist is non-empty', () {
        final searchPayload = AgentDefinition.searchAgent().toInitializePayload();
        expect(searchPayload['tools'], ['web_search', 'web_fetch']);

        const unrestricted = AgentDefinition(id: 'test', description: 'Test', prompt: 'Test prompt');
        expect(unrestricted.toInitializePayload(), isNot(contains('tools')));
      });
    });
  });
}
