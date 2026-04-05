import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

WorkflowDefinition _buildDef({
  String name = 'test',
  String description = 'Test workflow',
  Map<String, WorkflowVariable> variables = const {},
  List<WorkflowStep> steps = const [],
  List<WorkflowLoop> loops = const [],
}) {
  return WorkflowDefinition(
    name: name,
    description: description,
    variables: variables,
    steps: steps.isEmpty
        ? [const WorkflowStep(id: 's1', name: 'S1', prompt: 'Do it')]
        : steps,
    loops: loops,
  );
}

WorkflowStep _step({
  String id = 's1',
  String name = 'Step',
  String prompt = 'Do it',
  List<String> contextInputs = const [],
  List<String> contextOutputs = const [],
  String? gate,
}) =>
    WorkflowStep(
      id: id,
      name: name,
      prompt: prompt,
      contextInputs: contextInputs,
      contextOutputs: contextOutputs,
      gate: gate,
    );

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  group('WorkflowDefinitionValidator', () {
    test('valid definition returns empty error list', () {
      final def = _buildDef();
      expect(validator.validate(def), isEmpty);
    });

    group('required fields', () {
      test('missing name produces missingField error', () {
        final def = _buildDef(name: '');
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.missingField), true);
      });

      test('missing description produces missingField error', () {
        final def = _buildDef(description: '');
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.missingField), true);
      });

      test('empty steps list produces missingField error', () {
        final def = WorkflowDefinition(
          name: 'n',
          description: 'd',
          steps: const [],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.missingField), true);
      });
    });

    group('duplicate IDs', () {
      test('duplicate step IDs produces duplicateId error', () {
        final def = _buildDef(
          steps: [
            _step(id: 'same'),
            _step(id: 'same', name: 'S2', prompt: 'p'),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.duplicateId && e.stepId == 'same'), true);
      });

      test('duplicate loop IDs produces duplicateId error', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1'),
            _step(id: 's2', name: 'S2', prompt: 'p'),
          ],
          loops: [
            const WorkflowLoop(id: 'loop-x', steps: ['s1'], maxIterations: 2, exitGate: ''),
            const WorkflowLoop(id: 'loop-x', steps: ['s2'], maxIterations: 2, exitGate: ''),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.duplicateId && e.loopId == 'loop-x'), true);
      });
    });

    group('variable references', () {
      test('undeclared variable reference in prompt produces invalidReference error', () {
        final def = _buildDef(
          steps: [_step(prompt: 'Do {{UNDECLARED}}')],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });

      test('declared variable reference in prompt produces no error', () {
        final def = _buildDef(
          variables: {'VAR': const WorkflowVariable(description: 'v')},
          steps: [_step(prompt: 'Do {{VAR}}')],
        );
        expect(validator.validate(def), isEmpty);
      });

      test('context reference in prompt does not trigger variable reference error', () {
        final def = _buildDef(
          steps: [_step(prompt: 'Use {{context.key}}')],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), false);
      });

      test('undeclared variable in project field produces invalidReference error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(
              id: 's1',
              name: 'S',
              prompt: 'p',
              project: '{{UNDECLARED}}',
            ),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });
    });

    group('context key consistency', () {
      test('context input referencing key not in preceding step outputs produces contextInconsistency', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', contextInputs: ['key_a'], contextOutputs: []),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.contextInconsistency), true);
      });

      test('context input valid when preceding step declares the output', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', contextOutputs: ['result']),
            _step(id: 's2', name: 'S2', prompt: 'p', contextInputs: ['result']),
          ],
        );
        expect(validator.validate(def), isEmpty);
      });

      test('context input valid within same loop', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', contextInputs: ['loop_key'], contextOutputs: ['loop_key']),
            _step(id: 's2', name: 'S2', prompt: 'p', contextOutputs: []),
          ],
          loops: [
            const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: 3, exitGate: ''),
          ],
        );
        expect(validator.validate(def), isEmpty);
      });
    });

    group('gate expressions', () {
      test('valid gate expression produces no error', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', contextOutputs: ['status']),
            _step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status == done'),
          ],
        );
        expect(validator.validate(def), isEmpty);
      });

      test('gate referencing non-existent step produces invalidReference error', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', gate: 'nonexistent.status == done'),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });

      test('gate with invalid operator produces invalidGate error', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1'),
            _step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status INVALID done'),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.invalidGate), true);
      });

      test('compound gate with && is parsed correctly', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', contextOutputs: ['status', 'score']),
            _step(
              id: 's2',
              name: 'S2',
              prompt: 'p',
              gate: 's1.status == done && s1.score >= 90',
            ),
          ],
        );
        expect(validator.validate(def), isEmpty);
      });
    });

    group('loop references', () {
      test('loop referencing non-existent step produces invalidReference error', () {
        final def = _buildDef(
          steps: [_step(id: 's1')],
          loops: [
            const WorkflowLoop(
              id: 'lp',
              steps: ['nonexistent'],
              maxIterations: 3,
              exitGate: '',
            ),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });

      test('loop with maxIterations 0 produces missingMaxIterations error', () {
        final def = _buildDef(
          steps: [_step(id: 's1')],
          loops: [
            const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: 0, exitGate: ''),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.missingMaxIterations), true);
      });

      test('loop with negative maxIterations produces missingMaxIterations error', () {
        final def = _buildDef(
          steps: [_step(id: 's1')],
          loops: [
            const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: -1, exitGate: ''),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.missingMaxIterations), true);
      });

      test('step appearing in multiple loops produces loopOverlap error', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1'),
            _step(id: 's2', name: 'S2', prompt: 'p'),
          ],
          loops: [
            const WorkflowLoop(id: 'lp1', steps: ['s1'], maxIterations: 3, exitGate: ''),
            const WorkflowLoop(id: 'lp2', steps: ['s1', 's2'], maxIterations: 3, exitGate: ''),
          ],
        );
        final errors = validator.validate(def);
        expect(errors.any((e) => e.type == ValidationErrorType.loopOverlap), true);
      });
    });

    test('multiple errors are all collected (not fail-fast)', () {
      final def = WorkflowDefinition(
        name: '',
        description: '',
        steps: const [],
      );
      final errors = validator.validate(def);
      expect(errors.length, greaterThan(1));
    });
  });
}
