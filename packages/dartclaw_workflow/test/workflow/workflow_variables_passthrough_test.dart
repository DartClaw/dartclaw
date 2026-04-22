import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _definitionsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'lib', 'src', 'workflow', 'definitions'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow definitions dir');
    }
    current = parent;
  }
}

WorkflowDefinition _load(String fileName) {
  final yaml = File(p.join(_definitionsDir(), fileName)).readAsStringSync();
  return WorkflowDefinitionParser().parse(yaml);
}

void main() {
  group('Built-in workflow variable passthrough contract', () {
    test('plan-and-implement: only prd and discover-project opt in to REQUIREMENTS', () {
      final def = _load('plan-and-implement.yaml');
      final prd = def.steps.firstWhere((s) => s.id == 'prd');
      expect(prd.workflowVariables, ['REQUIREMENTS']);

      // discover-project also receives REQUIREMENTS so it can detect when the
      // input resolves to a pre-authored PRD/plan file and emit a fast-path
      // signal for the prd step's entryGate. No other step should opt in.
      final discover = def.steps.firstWhere((s) => s.id == 'discover-project');
      expect(discover.workflowVariables, ['REQUIREMENTS']);

      for (final step in def.steps) {
        if (step.id == 'prd' || step.id == 'discover-project') continue;
        expect(
          step.workflowVariables,
          isEmpty,
          reason: 'step "${step.id}" must not opt in to REQUIREMENTS',
        );
      }
    });

    test('plan-and-implement: no step leaks REQUIREMENTS via inline prompt reference', () {
      final def = _load('plan-and-implement.yaml');
      final engine = WorkflowTemplateEngine();
      for (final step in def.steps) {
        if (step.id == 'prd') continue;
        for (final prompt in step.prompts ?? const <String>[]) {
          final refs = engine.extractVariableReferences(prompt);
          expect(
            refs.contains('REQUIREMENTS'),
            isFalse,
            reason: 'step "${step.id}" must not reference {{REQUIREMENTS}} directly in its prompt',
          );
          expect(
            prompt.contains('<REQUIREMENTS>'),
            isFalse,
            reason: 'step "${step.id}" must not inline a <REQUIREMENTS> block',
          );
        }
      }
    });

    test('spec-and-implement: only spec and discover-project opt in to FEATURE', () {
      final def = _load('spec-and-implement.yaml');
      final spec = def.steps.firstWhere((s) => s.id == 'spec');
      expect(spec.workflowVariables, ['FEATURE']);

      // discover-project also receives FEATURE so it can detect when the input
      // resolves to a pre-authored FIS file and emit `spec_path` for the spec
      // step's entryGate. No other step should opt in.
      final discover = def.steps.firstWhere((s) => s.id == 'discover-project');
      expect(discover.workflowVariables, ['FEATURE']);

      for (final step in def.steps) {
        if (step.id == 'spec' || step.id == 'discover-project') continue;
        expect(
          step.workflowVariables,
          isEmpty,
          reason: 'step "${step.id}" must not opt in to FEATURE',
        );
      }
    });

    test('spec-and-implement: no step leaks FEATURE via inline prompt reference', () {
      final def = _load('spec-and-implement.yaml');
      final engine = WorkflowTemplateEngine();
      for (final step in def.steps) {
        if (step.id == 'spec') continue;
        for (final prompt in step.prompts ?? const <String>[]) {
          final refs = engine.extractVariableReferences(prompt);
          expect(
            refs.contains('FEATURE'),
            isFalse,
            reason: 'step "${step.id}" must not reference {{FEATURE}} directly in its prompt',
          );
          expect(
            prompt.contains('<FEATURE>'),
            isFalse,
            reason: 'step "${step.id}" must not inline a <FEATURE> block',
          );
        }
      }
    });
  });
}
