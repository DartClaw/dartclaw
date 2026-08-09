import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('AgentDefinition', () {
    group('searchAgent factory', () {
      test('leaves the search model provider-neutral', () {
        final agent = AgentDefinition.searchAgent();
        expect(agent.model, isNull);
        expect(agent.provider, isNull);
        expect(agent.securityProfile, 'restricted');
      });

      test('allows model override', () {
        final agent = AgentDefinition.searchAgent(model: 'custom-model');
        expect(agent.model, 'custom-model');
      });

      test('sets expected defaults', () {
        final agent = AgentDefinition.searchAgent();
        expect(agent.id, 'search');
        expect(agent.allowedTools, containsAll(['web_search', 'web_fetch']));
      });
    });

    group('fromYaml', () {
      test('parses provider and model fields', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {'provider': ' OpenAI-Work ', 'model': 'gpt-5.6-luna'}, warns);
        expect(agent.provider, 'openai-work');
        expect(agent.model, 'gpt-5.6-luna');
        expect(warns, isEmpty);
      });

      test('invalid provider falls back to the deployment default', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('reviewer', const {
          'provider': 42,
          'tools': ['file_read'],
        }, warns);

        expect(agent.provider, isNull);
        expect(warns, contains(contains('Invalid agents.reviewer.provider')));
      });

      test('parses a provider-independent security profile', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('reviewer', {
          'security_profile': 'workspace',
          'tools': ['file_read'],
        }, warns);

        expect(agent.securityProfile, 'workspace');
        expect(warns, isEmpty);
      });

      test('defaults search to restricted and other agents to provider default', () {
        final searchWarnings = <String>[];
        final agentWarnings = <String>[];

        expect(AgentDefinition.fromYaml('search', const {}, searchWarnings).securityProfile, 'restricted');
        expect(
          AgentDefinition.fromYaml('reviewer', const {
            'tools': ['file_read'],
          }, agentWarnings).securityProfile,
          isNull,
        );
        expect(searchWarnings, isEmpty);
        expect(agentWarnings, isEmpty);
      });

      test('invalid security profile warns and uses the agent default', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', const {'security_profile': 'host'}, warns);

        expect(agent.securityProfile, 'restricted');
        expect(warns, contains(contains('Invalid agents.search.security_profile')));
      });

      test('model is null when not specified', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('search', {'description': 'Test agent'}, warns);
        expect(agent.model, isNull);
      });

      test('custom agents do not inherit the search persona', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('reviewer', const {
          'tools': ['file_read'],
        }, warns);

        expect(agent.prompt, isEmpty);
        expect(warns, isEmpty);
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
    });

    test('uses value equality for configuration change detection', () {
      const first = AgentDefinition(
        id: 'reviewer',
        description: 'Reviews changes',
        prompt: 'Review carefully',
        provider: 'codex',
        securityProfile: 'restricted',
        allowedTools: {'file_read', 'web_search'},
        deniedTools: {'shell'},
        maxResponseBytes: 4096,
        model: 'review-model',
        effort: 'high',
      );
      const same = AgentDefinition(
        id: 'reviewer',
        description: 'Reviews changes',
        prompt: 'Review carefully',
        provider: 'codex',
        securityProfile: 'restricted',
        allowedTools: {'web_search', 'file_read'},
        deniedTools: {'shell'},
        maxResponseBytes: 4096,
        model: 'review-model',
        effort: 'high',
      );
      const differentProfile = AgentDefinition(
        id: 'reviewer',
        description: 'Reviews changes',
        prompt: 'Review carefully',
        provider: 'codex',
        securityProfile: 'workspace',
        allowedTools: {'file_read', 'web_search'},
        deniedTools: {'shell'},
        maxResponseBytes: 4096,
        model: 'review-model',
        effort: 'high',
      );

      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first, isNot(differentProfile));
    });
  });
}
