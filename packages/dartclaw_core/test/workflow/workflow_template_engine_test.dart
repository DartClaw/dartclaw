import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

WorkflowContext _ctx({
  Map<String, dynamic>? data,
  Map<String, String>? variables,
}) =>
    WorkflowContext(data: data, variables: variables);

void main() {
  late WorkflowTemplateEngine engine;

  setUp(() {
    engine = WorkflowTemplateEngine();
  });

  group('WorkflowTemplateEngine.resolve', () {
    test('resolves variable reference', () {
      final ctx = _ctx(variables: {'NAME': 'Alice'});
      expect(engine.resolve('Hello {{NAME}}!', ctx), 'Hello Alice!');
    });

    test('resolves context reference', () {
      final ctx = _ctx(data: {'result': 'success'});
      expect(engine.resolve('Status: {{context.result}}', ctx), 'Status: success');
    });

    test('resolves multiple references in same template', () {
      final ctx = _ctx(
        data: {'key': 'world'},
        variables: {'GREETING': 'Hello'},
      );
      expect(
        engine.resolve('{{GREETING}} {{context.key}}!', ctx),
        'Hello world!',
      );
    });

    test('template with no references returned unchanged', () {
      final ctx = _ctx();
      expect(engine.resolve('No references here', ctx), 'No references here');
    });

    test('missing variable throws ArgumentError', () {
      final ctx = _ctx();
      expect(
        () => engine.resolve('{{MISSING}}', ctx),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing context key resolves to empty string', () {
      final ctx = _ctx();
      expect(engine.resolve('{{context.missing}}', ctx), '');
    });

    test('whitespace in braces is trimmed and resolved', () {
      final ctx = _ctx(variables: {'VAR': 'value'});
      expect(engine.resolve('{{ VAR }}', ctx), 'value');
    });

    test('context reference with trimmed whitespace works', () {
      final ctx = _ctx(data: {'k': 'v'});
      expect(engine.resolve('{{ context.k }}', ctx), 'v');
    });
  });

  group('WorkflowTemplateEngine.extractVariableReferences', () {
    test('extracts non-context references', () {
      expect(
        engine.extractVariableReferences('{{A}} and {{context.x}} and {{B}}'),
        {'A', 'B'},
      );
    });

    test('returns empty set when no references', () {
      expect(engine.extractVariableReferences('no refs'), isEmpty);
    });

    test('ignores context references', () {
      expect(
        engine.extractVariableReferences('{{context.key}}'),
        isEmpty,
      );
    });
  });

  group('WorkflowTemplateEngine.extractContextReferences', () {
    test('extracts context key references without prefix', () {
      expect(
        engine.extractContextReferences('{{context.result}} and {{context.status}}'),
        {'result', 'status'},
      );
    });

    test('ignores variable references', () {
      expect(engine.extractContextReferences('{{VAR}}'), isEmpty);
    });

    test('returns empty set when no context refs', () {
      expect(engine.extractContextReferences('hello world'), isEmpty);
    });
  });
}
