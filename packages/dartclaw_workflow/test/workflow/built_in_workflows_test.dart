import 'package:dartclaw_workflow/dartclaw_workflow.dart' show builtInWorkflowYaml;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('builtInWorkflowYaml', () {
    test('contains the four surviving workflows', () {
      expect(
        builtInWorkflowYaml.keys,
        unorderedEquals(<String>[
          'spec-and-implement',
          'plan-and-implement',
          'code-review',
          'research-and-evaluate',
        ]),
      );
      expect(builtInWorkflowYaml, hasLength(4));
    });

    test('each workflow definition has the expected top-level structure', () {
      for (final entry in builtInWorkflowYaml.entries) {
        final parsed = loadYaml(entry.value);
        expect(parsed, isA<YamlMap>());

        final workflow = parsed as YamlMap;
        expect(workflow['name'], entry.key);
        expect(workflow['steps'], isA<YamlList>());
        expect((workflow['steps'] as YamlList), isNotEmpty);
        expect(entry.value.toString().contains('evaluator:'), isFalse);
      }
    });
  });
}
