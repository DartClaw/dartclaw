import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
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

      test('rejects an explicitly blank provider', () {
        expect(
          () => AgentDefinition.fromYaml('reviewer', const {'provider': ' '}, <String>[]),
          throwsA(isA<FormatException>()),
        );
      });

      test('parses a provider-independent security profile', () {
        final warns = <String>[];
        final agent = AgentDefinition.fromYaml('reviewer', {
          'security_profile': 'workspace',
          'tools': ['file_read'],
        }, warns);

        expect(agent.securityProfile, 'workspace');
        expect(agent.profileIsOperatorConfigured, isTrue);
        expect(warns, isEmpty);
      });

      test('a defaulted profile is distinguishable from an operator-configured one', () {
        // The resolver may drop a default profile when a host mode is inherited
        // but must reject discarding a configured one.
        final warns = <String>[];

        expect(AgentDefinition.fromYaml('search', const {}, warns).profileIsOperatorConfigured, isFalse);
        expect(
          AgentDefinition.fromYaml('search', const {
            'security_profile': 'restricted',
          }, warns).profileIsOperatorConfigured,
          isTrue,
        );
        expect(
          AgentDefinition.fromYaml('search', const {'security_profile': 'nonsense'}, warns).profileIsOperatorConfigured,
          isFalse,
          reason: 'an invalid value falls back to the default, which is not operator-configured',
        );
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

      group('workspace binding', () {
        late Directory dataDir;
        late String ownerDir;

        setUp(() {
          dataDir = Directory.systemTemp.createTempSync('agent_workspace_config_');
          dataDir = Directory(dataDir.resolveSymbolicLinksSync());
          ownerDir = p.join(dataDir.path, 'workspace');
          Directory(ownerDir).createSync();
        });

        tearDown(() {
          if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        });

        test('omitted paths derive distinct managed bindings without touching disk', () {
          final yaml =
              '''
data_dir: "${dataDir.path}"
agent:
  agents:
    a:
      tools: [Read]
    b:
      tools: [Read]
''';

          final config = DartclawConfig.load(
            configPath: 'dartclaw.yaml',
            fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
            env: const {'HOME': '/home/user'},
            resolveStoredCredentials: false,
          );
          final definitions = {for (final definition in config.agent.definitions) definition.id: definition};

          expect(definitions['a']!.workspace?.directory, p.join(dataDir.path, 'agents', 'a', 'workspace'));
          expect(definitions['a']!.workspace?.storagePrincipal, 'agent:a');
          expect(definitions['b']!.workspace?.directory, p.join(dataDir.path, 'agents', 'b', 'workspace'));
          expect(definitions.values.every((definition) => definition.workspaceConfigurationError == null), isTrue);
          expect(Directory(p.join(dataDir.path, 'agents')).existsSync(), isFalse);
        });

        test('every obsolete workspace value refuses without adopting its path', () {
          for (final value in <Object?>[null, '', 'legacy', p.join(dataDir.path, 'legacy')]) {
            final warnings = <String>[];
            final definition = AgentDefinition.fromYaml(
              'a',
              {
                'workspace': value,
                'tools': ['Read'],
              },
              warnings,
              dataDir: dataDir.path,
              ownerWorkspaceDir: ownerDir,
            );

            expect(definition.workspace, isNull, reason: 'value=$value');
            expect(
              definition.workspaceConfigurationError,
              allOf(contains('agent.agents.a.workspace'), contains('no longer')),
            );
            expect(definition.requireWorkspaceAvailable, throwsStateError);
            expect(warnings, contains(definition.workspaceConfigurationError));
          }
          expect(Directory(p.join(dataDir.path, 'agents')).existsSync(), isFalse);
        });

        test('reserved and unsafe ids cannot collide with owner or peer homes', () {
          for (final id in ['main', '../peer', 'Peer', '.hidden', 'a/b', '']) {
            final definition = AgentDefinition.fromYaml(
              id,
              const {
                'tools': ['Read'],
              },
              <String>[],
              dataDir: dataDir.path,
              ownerWorkspaceDir: ownerDir,
            );

            expect(definition.workspace, isNull, reason: 'id=$id');
            expect(definition.workspaceConfigurationError, isNotNull, reason: 'id=$id');
            expect(definition.requireWorkspaceAvailable, throwsStateError, reason: 'id=$id');
          }

          final safe = AgentWorkspace.managed(agentId: 'peer_2', dataDir: dataDir.path, ownerWorkspaceDir: ownerDir);
          expect(safe.directory, p.join(dataDir.path, 'agents', 'peer_2', 'workspace'));
          expect(p.isWithin(dataDir.path, safe.directory), isTrue);
          expect(p.isWithin(ownerDir, safe.directory), isFalse);
        });
      });
    });

    test('workspace path equality is preserved in hashed collections', () {
      final canonical = p.join(p.separator, 'srv', 'agents', 'researcher');
      final equivalent = '$canonical${p.separator}';
      final first = AgentWorkspace(agentId: 'researcher', directory: canonical);
      final second = AgentWorkspace(agentId: 'researcher', directory: equivalent);

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect({first, second}, hasLength(1));
      expect({first: 'first', second: 'second'}, {first: 'second'});
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

  _outputSchemaTests();
}

void _outputSchemaTests() {
  group('AgentDefinition.fromYaml output_schema', () {
    AgentDefinition parse(Object? schema, {bool present = true}) {
      final warns = <String>[];
      final agent = AgentDefinition.fromYaml('researcher', {
        'prompt': 'Research',
        'tools': ['web_search'],
        if (present) 'output_schema': schema,
      }, warns);
      expect(warns, isEmpty);
      return agent;
    }

    void expectRejected(Object? schema, {required String keyword, required String pointer}) {
      expect(
        () => parse(schema),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('agent.agents.researcher.output_schema'))
              .having((e) => e.message, 'message', contains(keyword))
              .having((e) => e.message, 'message', contains(pointer)),
        ),
        reason: '$schema',
      );
    }

    test('an absent output_schema leaves the definition unschema-bound', () {
      expect(parse(null, present: false).outputSchema, isNull);
    });

    test('rejects a keyword the validator does not enforce', () {
      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer', 'minimum': 3},
          },
        },
        keyword: 'minimum',
        pointer: '/properties/n/minimum',
      );

      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {'type': 'string', r'$ref': '#/defs/n'},
          },
        },
        keyword: r'$ref',
        pointer: r'/properties/n/$ref',
      );

      expectRejected(
        {
          'type': 'object',
          'oneOf': [
            {'type': 'object'},
          ],
        },
        keyword: 'oneOf',
        pointer: '/oneOf',
      );

      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {'type': 'string', 'default': 'x'},
          },
        },
        keyword: 'default',
        pointer: '/properties/n/default',
      );
    });

    test('rejects a non-map, an explicit null, and an empty map', () {
      expectRejected('not-a-map', keyword: 'mapping', pointer: 'schema root');
      expectRejected(null, keyword: 'mapping', pointer: 'schema root');
      expectRejected(<String, dynamic>{}, keyword: 'empty', pointer: 'schema root');
    });

    test('rejects a schema map with no single-string type', () {
      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {'description': 'typeless'},
          },
        },
        keyword: 'type',
        pointer: '/properties/n/type',
      );

      expectRejected(
        {
          'type': ['object', 'null'],
        },
        keyword: 'type',
        pointer: '/type',
      );
    });

    test('rejects an array schema without a single items schema', () {
      expectRejected(
        {
          'type': 'object',
          'properties': {
            'rows': {'type': 'array'},
          },
        },
        keyword: 'items',
        pointer: '/properties/rows/items',
      );

      expectRejected(
        {
          'type': 'object',
          'properties': {
            'rows': {
              'type': 'array',
              'items': [
                {'type': 'string'},
              ],
            },
          },
        },
        keyword: 'items',
        pointer: '/properties/rows/items',
      );

      expectRejected(
        {
          'type': 'object',
          'properties': {
            'rows': {'type': 'array', 'items': <String, dynamic>{}},
          },
        },
        keyword: 'empty',
        pointer: '/properties/rows/items',
      );
    });

    test('rejects a supported keyword declared under the wrong type', () {
      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {
              'type': 'string',
              'properties': {
                'inner': {'type': 'string'},
              },
            },
          },
        },
        keyword: 'properties',
        pointer: '/properties/n/properties',
      );

      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {
              'type': 'string',
              'items': {'type': 'string'},
            },
          },
        },
        keyword: 'items',
        pointer: '/properties/n/items',
      );

      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {
              'type': 'object',
              'enum': ['a'],
            },
          },
        },
        keyword: 'enum',
        pointer: '/properties/n/enum',
      );
    });

    test('accepts and drops title/description/\$schema annotations', () {
      final agent = parse({
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        'title': 'Findings',
        'type': 'object',
        'properties': {
          'answer': {'type': 'string', 'description': 'The answer'},
        },
      });

      final schema = agent.outputSchema!;
      expect(schema.keys, equals(['type', 'properties', 'required', 'additionalProperties']));
      final answer = (schema['properties'] as Map)['answer'] as Map<String, dynamic>;
      expect(answer.keys, equals(['type']));
    });

    test('rejects a required name absent from properties', () {
      expectRejected(
        {
          'type': 'object',
          'properties': {
            'a': {'type': 'string'},
          },
          'required': ['b'],
        },
        keyword: 'required',
        pointer: '/required',
      );
    });

    test('rejects a degenerate enum', () {
      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {'type': 'string', 'enum': <Object?>[]},
          },
        },
        keyword: 'enum',
        pointer: '/properties/n/enum',
      );

      expectRejected(
        {
          'type': 'object',
          'properties': {
            'n': {
              'type': 'integer',
              'enum': [1, 'a'],
            },
          },
        },
        keyword: 'enum',
        pointer: '/properties/n/enum',
      );
    });

    test('rejects a schema-valued additionalProperties and a non-object root', () {
      expectRejected(
        {
          'type': 'object',
          'additionalProperties': {'type': 'string'},
        },
        keyword: 'additionalProperties',
        pointer: '/additionalProperties',
      );

      expectRejected(
        {
          'type': 'array',
          'items': {'type': 'string'},
        },
        keyword: 'root schema',
        pointer: '/type',
      );
    });

    test('overrides a declared additionalProperties: true to false', () {
      final agent = parse({'type': 'object', 'additionalProperties': true});
      expect(agent.outputSchema!['additionalProperties'], isFalse);
    });

    test('stores a supported schema deep-closed', () {
      final agent = parse({
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'rows': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'cell': {'type': 'string'},
              },
            },
          },
        },
        'required': ['title'],
      });

      final schema = agent.outputSchema!;
      expect(schema['additionalProperties'], isFalse);
      final rows = (schema['properties'] as Map)['rows'] as Map<String, dynamic>;
      expect((rows['items'] as Map)['additionalProperties'], isFalse);
      expect(schema['required'], equals(['title']));
    });

    test('personaPrompt equals prompt when no schema is declared', () {
      final agent = parse(null, present: false);
      expect(agent.personaPrompt, agent.prompt);
      expect(agent.personaPrompt, 'Research');
    });

    test('personaPrompt appends the rendered contract when a schema is declared', () {
      final agent = parse({
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'score': {'type': 'integer'},
        },
        'required': ['title'],
      });

      final persona = agent.personaPrompt;
      expect(persona, startsWith('Research'));
      expect(persona, contains('title'));
      expect(persona, contains('score'));
      expect(persona, contains('integer'));
      expect(persona, contains('Required top-level properties: title.'));
      expect(persona, contains('additionalProperties'));
      expect(persona.toLowerCase(), contains('only the json value'));
      expect(persona.toLowerCase(), contains('code fence'));
    });

    test('personaPrompt is the contract alone when the prompt is blank', () {
      final warns = <String>[];
      final agent = AgentDefinition.fromYaml('researcher', {
        'prompt': '   ',
        'tools': ['web_search'],
        'output_schema': {'type': 'object'},
      }, warns);

      expect(agent.personaPrompt, renderOutputSchemaContract(agent.outputSchema!));
      expect(agent.personaPrompt.trim(), isNotEmpty);
    });

    test('compares output schemas by value so an unchanged config is not seen as changed', () {
      final first = parse({
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
        },
      });
      final same = parse({
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
        },
      });
      final different = parse({
        'type': 'object',
        'properties': {
          'title': {'type': 'integer'},
        },
      });

      expect(first, equals(same));
      expect(first.hashCode, equals(same.hashCode));
      expect(first, isNot(equals(different)));
    });
  });
}
