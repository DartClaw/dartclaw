import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

const _header = '''
name: test-workflow
description: Test
steps:
''';

void main() {
  group('TD-086 mechanical slice — extraction field errors', () {
    final parser = WorkflowDefinitionParser();

    test('extraction.type is non-string (int) throws FormatException naming the field', () {
      const yaml =
          '''
$_header
  - id: step1
    name: Step One
    prompt: Do something
    extraction:
      type: 42
      pattern: "foo"
''';
      expect(
        () => parser.parse(yaml, sourcePath: 'test/fixture.yaml'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('extraction.type'), contains('test/fixture.yaml')),
          ),
        ),
      );
    });

    test('extraction.type is unknown enum value throws FormatException listing valid values', () {
      const yaml =
          '''
$_header
  - id: step1
    name: Step One
    prompt: Do something
    extraction:
      type: unknown_value
      pattern: "foo"
''';
      expect(
        () => parser.parse(yaml, sourcePath: 'test/fixture.yaml'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('extraction.type'), contains('unknown_value'), contains('artifact')),
          ),
        ),
      );
    });

    test('extraction.pattern missing throws FormatException naming extraction.pattern', () {
      const yaml =
          '''
$_header
  - id: step1
    name: Step One
    prompt: Do something
    extraction:
      type: artifact
''';
      expect(
        () => parser.parse(yaml, sourcePath: 'test/fixture.yaml'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('extraction.pattern'), contains('test/fixture.yaml')),
          ),
        ),
      );
    });
  });
}
