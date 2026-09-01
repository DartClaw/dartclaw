import 'package:test/test.dart';

import 'support/load_config.dart';

/// The `researcher` example from `docs/guide/configuration.md`, verbatim in
/// shape: it must survive the real YAML loader, not just a literal Dart map.
/// `AgentDefinition.fromYaml` receives an unmodifiable `YamlMap` with `dynamic`
/// keys, so a deep-close that mutated or cast its input would throw only here.
const _documentedExample = '''
agent:
  agents:
    researcher:
      description: "Researches a question and returns structured findings"
      security_profile: restricted
      tools: [web_search, web_fetch]
      prompt: "Research the question and report what you found."
      output_schema:
        type: object
        properties:
          answer: {type: string}
          sources:
            type: array
            items:
              type: object
              properties:
                url: {type: string}
                title: {type: string}
              required: [url]
        required: [answer, sources]
''';

void main() {
  group('agent.agents.<id>.output_schema through the real YAML loader', () {
    test('the documented example loads with no warnings and is stored deep-closed', () {
      final config = loadYaml(_documentedExample, configPath: 'dartclaw.yaml', env: const {'HOME': '/tmp'});

      expect(config.warnings, isEmpty);
      final researcher = config.agent.definitions.singleWhere((d) => d.id == 'researcher');
      final schema = researcher.outputSchema!;

      expect(schema['additionalProperties'], isFalse);
      expect(schema['required'], equals(['answer', 'sources']));
      final sources = (schema['properties'] as Map)['sources'] as Map<String, dynamic>;
      final sourceItem = sources['items'] as Map<String, dynamic>;
      expect(sourceItem['additionalProperties'], isFalse);
      expect(sourceItem['required'], equals(['url']));
      expect(schema, isA<Map<String, dynamic>>());
    });

    test('the rendered persona carries the contract from the loaded schema', () {
      final config = loadYaml(_documentedExample, configPath: 'dartclaw.yaml', env: const {'HOME': '/tmp'});
      final researcher = config.agent.definitions.singleWhere((d) => d.id == 'researcher');

      final persona = researcher.personaPrompt;
      expect(persona, startsWith('Research the question and report what you found.'));
      expect(persona, contains('answer'));
      expect(persona, contains('sources'));
      expect(persona.toLowerCase(), contains('only the json value'));
    });

    test('an unenforceable keyword in YAML is rejected at load', () {
      expect(
        () => loadYaml(
          '''
agent:
  agents:
    researcher:
      output_schema:
        type: object
        properties:
          n: {type: integer, minimum: 3}
''',
          configPath: 'dartclaw.yaml',
          env: const {'HOME': '/tmp'},
        ),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('agent.agents.researcher.output_schema'))
              .having((e) => e.message, 'message', contains('minimum'))
              .having((e) => e.message, 'message', contains('/properties/n/minimum')),
        ),
      );
    });

    test('explicitly null object keywords are rejected through YAML', () {
      for (final keyword in ['properties', 'required', 'additionalProperties']) {
        expect(
          () => loadYaml(
            '''
agent:
  agents:
    researcher:
      output_schema:
        type: object
        $keyword: null
''',
            configPath: 'dartclaw.yaml',
            env: const {'HOME': '/tmp'},
          ),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('/$keyword'))),
          reason: keyword,
        );
      }
    });
  });
}
