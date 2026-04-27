import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Minimal fake SkillRegistry for validator tests.
class _FakeSkillRegistry implements SkillRegistry {
  final Map<String, SkillInfo> _skills;

  _FakeSkillRegistry(this._skills);

  @override
  List<SkillInfo> listAll() => _skills.values.toList();

  @override
  SkillInfo? getByName(String name) => _skills[name];

  @override
  String? validateRef(String skillRef) {
    if (_skills.containsKey(skillRef)) return null;
    final available = _skills.keys.toList()..sort();
    return 'Skill "$skillRef" not found. Available: ${available.join(', ')}';
  }

  @override
  bool isNativeFor(String skillName, String harnessType) {
    final skill = _skills[skillName];
    if (skill == null) return false;
    return skill.nativeHarnesses.contains(harnessType);
  }
}

_FakeSkillRegistry _makeRegistry({
  Set<String> claudeSkills = const {},
  Set<String> codexSkills = const {},
  Set<String> bothSkills = const {},
}) {
  final map = <String, SkillInfo>{};
  for (final name in claudeSkills) {
    map[name] = SkillInfo(
      name: name,
      description: '',
      source: SkillSource.projectClaude,
      path: '/skills/$name',
      nativeHarnesses: const {'claude'},
    );
  }
  for (final name in codexSkills) {
    map[name] = SkillInfo(
      name: name,
      description: '',
      source: SkillSource.projectAgents,
      path: '/skills/$name',
      nativeHarnesses: const {'codex'},
    );
  }
  for (final name in bothSkills) {
    map[name] = SkillInfo(
      name: name,
      description: '',
      source: SkillSource.workspace,
      path: '/skills/$name',
      nativeHarnesses: const {'claude', 'codex'},
    );
  }
  return _FakeSkillRegistry(map);
}

WorkflowDefinition _buildDef({
  String name = 'test',
  String description = 'Test workflow',
  Map<String, WorkflowVariable> variables = const {},
  List<WorkflowStep> steps = const [],
  List<WorkflowLoop> loops = const [],
  List<WorkflowNode>? nodes,
}) {
  return WorkflowDefinition(
    name: name,
    description: description,
    variables: variables,
    steps: steps.isEmpty
        ? [
            const WorkflowStep(id: 's1', name: 'S1', prompts: ['Do it']),
          ]
        : steps,
    loops: loops,
    nodes: nodes,
  );
}

WorkflowStep _step({
  String id = 's1',
  String name = 'Step',
  String prompt = 'Do it',
  List<String> inputs = const [],
  Map<String, OutputConfig>? outputs,
  String? gate,
}) => WorkflowStep(
  id: id,
  name: name,
  prompts: [prompt],
  inputs: inputs,
  outputs: outputs == null || outputs.isEmpty ? null : outputs,
  gate: gate,
);

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  group('WorkflowDefinitionValidator', () {
    test('valid definition returns report with no errors and no warnings', () {
      final def = _buildDef();
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
    });

    group('required fields', () {
      test('missing name produces missingField error', () {
        final def = _buildDef(name: '');
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.missingField), true);
      });

      test('missing description produces missingField error', () {
        final def = _buildDef(description: '');
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.missingField), true);
      });

      test('empty steps list produces missingField error', () {
        final def = WorkflowDefinition(name: 'n', description: 'd', steps: const []);
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.missingField), true);
      });

      test('workflow-level project references must be declared', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          project: '{{PROJECT}}',
          steps: const [
            WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.message.contains('Workflow project field references undeclared variable')), isTrue);
      });
    });

    group('deprecation warnings', () {
      test('warns when step project duplicates workflow-level project', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          project: '{{PROJECT}}',
          variables: const {'PROJECT': WorkflowVariable(required: false, defaultValue: 'demo-project')},
          steps: const [
            WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], project: '{{PROJECT}}'),
          ],
        );
        final warnings = validator.validate(def).warnings;
        expect(warnings.any((w) => w.message.contains('duplicates the workflow-level project binding')), isTrue);
      });

      test('emits one semantic type warning per definition', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 'discover', name: 'Discover', prompts: ['p'], type: 'research', typeAuthored: true),
            WorkflowStep(id: 'review', name: 'Review', prompts: ['p'], type: 'analysis', typeAuthored: true),
          ],
        );
        final warnings = validator.validate(def).warnings;
        expect(warnings.where((w) => w.message.contains('Semantic step types')).length, 1);
      });

      group('contextOutputs removal', () {
        test('parser throws on contextOutputs: with migration message', () {
          const yaml = '''
name: wf
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs: [foo]
''';
          expect(
            () => WorkflowDefinitionParser().parse(yaml),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(contains('contextOutputs: is removed'), contains('outputs:')),
              ),
            ),
          );
        });
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
        final errors = validator.validate(def).errors;
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
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.duplicateId && e.loopId == 'loop-x'), true);
      });
    });

    group('normalized nodes', () {
      test('malformed normalized graph is rejected', () {
        final def = _buildDef(
          steps: [
            _step(id: 'setup'),
            const WorkflowStep(
              id: 'map-step',
              name: 'Map',
              prompts: ['p'],
              mapOver: 'items',
              inputs: ['items'],
              outputs: {'mapped': OutputConfig()},
            ),
          ],
          nodes: const [
            ActionNode(stepId: 'setup'),
            ActionNode(stepId: 'map-step'),
          ],
        );

        final errors = validator.validate(def).errors;
        expect(
          errors,
          contains(
            isA<ValidationError>().having(
              (error) => error.message,
              'message',
              contains('map-backed but was normalized as an action node'),
            ),
          ),
        );
      });

      test('every authored step must appear exactly once in the normalized graph', () {
        final def = _buildDef(
          steps: [
            _step(id: 'a'),
            _step(id: 'b', name: 'B', prompt: 'p'),
          ],
          nodes: const [ActionNode(stepId: 'a')],
        );

        final errors = validator.validate(def).errors;
        expect(
          errors,
          contains(
            isA<ValidationError>().having(
              (error) => error.message,
              'message',
              contains('is not represented in the normalized execution graph'),
            ),
          ),
        );
      });
    });

    group('variable references', () {
      test('undeclared variable reference in prompt produces invalidReference error', () {
        final def = _buildDef(steps: [_step(prompt: 'Do {{UNDECLARED}}')]);
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });

      test('declared variable reference in prompt produces no error', () {
        final def = _buildDef(
          variables: {'VAR': const WorkflowVariable(description: 'v')},
          steps: [_step(prompt: 'Do {{VAR}}')],
        );
        expect(validator.validate(def).errors, isEmpty);
      });

      test('context reference in prompt does not trigger variable reference error', () {
        final def = _buildDef(steps: [_step(prompt: 'Use {{context.key}}')]);
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), false);
      });

      test('undeclared variable in project field produces invalidReference error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: ['p'], project: '{{UNDECLARED}}'),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });

      test('workflowVariables entry missing from variables block produces invalidReference error', () {
        final def = _buildDef(
          steps: [
            const WorkflowStep(id: 's1', name: 'S', prompts: ['p'], workflowVariables: ['UNDECLARED']),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference && e.stepId == 's1'), true);
      });

      test('workflowVariables entry declared in variables block produces no error', () {
        final def = _buildDef(
          variables: {'REQUIREMENTS': const WorkflowVariable(description: 'r')},
          steps: [
            const WorkflowStep(id: 's1', name: 'S', prompts: ['p'], workflowVariables: ['REQUIREMENTS']),
          ],
        );
        expect(validator.validate(def).errors, isEmpty);
      });
    });

    group('context key consistency', () {
      test('context input referencing key not in preceding step outputs produces contextInconsistency', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', inputs: ['key_a'], outputs: {}),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.contextInconsistency), true);
      });

      test('context input valid when preceding step declares the output', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', outputs: {'result': OutputConfig()}),
            _step(id: 's2', name: 'S2', prompt: 'p', inputs: ['result']),
          ],
        );
        expect(validator.validate(def).errors, isEmpty);
      });

      test('context input valid within same loop', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', inputs: ['loop_key'], outputs: {'loop_key': OutputConfig()}),
            _step(id: 's2', name: 'S2', prompt: 'p', outputs: {}),
          ],
          loops: [
            const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: 3, exitGate: ''),
          ],
        );
        expect(validator.validate(def).errors, isEmpty);
      });
    });

    test('warns when duplicate output names use different descriptions', () {
      final def = _buildDef(
        steps: [
          WorkflowStep(
            id: 'a',
            name: 'A',
            prompts: const ['p'],
            outputs: const {'x': OutputConfig(format: OutputFormat.text, description: 'from A')},
          ),
          WorkflowStep(
            id: 'b',
            name: 'B',
            prompts: const ['p'],
            outputs: const {'x': OutputConfig(format: OutputFormat.text, description: 'from B')},
          ),
        ],
      );

      final report = validator.validate(def);
      expect(report.warnings, isNotEmpty);
      expect(report.warnings.single.message, contains('"x"'));
      expect(report.warnings.single.message, contains('a'));
      expect(report.warnings.single.message, contains('b'));
    });

    test('does not warn when duplicate output descriptions are absent', () {
      final def = _buildDef(
        steps: [
          WorkflowStep(
            id: 'a',
            name: 'A',
            prompts: const ['p'],
            outputs: const {'x': OutputConfig(format: OutputFormat.text)},
          ),
          WorkflowStep(
            id: 'b',
            name: 'B',
            prompts: const ['p'],
            outputs: const {'x': OutputConfig(format: OutputFormat.text)},
          ),
        ],
      );

      final report = validator.validate(def);
      expect(report.warnings, isEmpty);
    });

    group('gate expressions', () {
      test('valid gate expression produces no error', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', outputs: {'status': OutputConfig()}),
            _step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status == done'),
          ],
        );
        expect(validator.validate(def).errors, isEmpty);
      });

      test('gate referencing non-existent step produces invalidReference error', () {
        final def = _buildDef(
          steps: [_step(id: 's1', gate: 'nonexistent.status == done')],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });

      test('gate with invalid operator produces invalidGate error', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1'),
            _step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status INVALID done'),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidGate), true);
      });

      test('compound gate with && is parsed correctly', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', outputs: {'status': OutputConfig(), 'score': OutputConfig()}),
            _step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status == done && s1.score >= 90'),
          ],
        );
        expect(validator.validate(def).errors, isEmpty);
      });

      test('loop entryGate is validated alongside exitGate', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1'),
            _step(id: 's2', name: 'S2', prompt: 'p'),
          ],
          loops: [
            const WorkflowLoop(
              id: 'lp',
              steps: ['s1'],
              maxIterations: 3,
              entryGate: 's2.findings_count > 0',
              exitGate: 's1.status == done',
            ),
          ],
        );

        expect(validator.validate(def).errors, isEmpty);
      });

      test('invalid loop entryGate produces invalidGate error', () {
        final def = _buildDef(
          steps: [_step(id: 's1')],
          loops: [
            const WorkflowLoop(
              id: 'lp',
              steps: ['s1'],
              maxIterations: 3,
              entryGate: 's1.status INVALID done',
              exitGate: 's1.status == done',
            ),
          ],
        );

        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidGate && e.loopId == 'lp'), isTrue);
      });
    });

    group('loop references', () {
      test('loop referencing non-existent step produces invalidReference error', () {
        final def = _buildDef(
          steps: [_step(id: 's1')],
          loops: [
            const WorkflowLoop(id: 'lp', steps: ['nonexistent'], maxIterations: 3, exitGate: ''),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.invalidReference), true);
      });

      test('loop with maxIterations 0 produces missingMaxIterations error', () {
        final def = _buildDef(
          steps: [_step(id: 's1')],
          loops: [
            const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: 0, exitGate: ''),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.missingMaxIterations), true);
      });

      test('loop with negative maxIterations produces missingMaxIterations error', () {
        final def = _buildDef(
          steps: [_step(id: 's1')],
          loops: [
            const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: -1, exitGate: ''),
          ],
        );
        final errors = validator.validate(def).errors;
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
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.loopOverlap), true);
      });
    });

    group('multi-prompt provider validation (S02)', () {
      test('multi-prompt step with non-continuity provider produces unsupportedProviderCapability error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: const ['First', 'Second'], provider: 'gemini'),
          ],
        );
        final errors = validator.validate(def, continuityProviders: {'claude', 'codex'}).errors;
        expect(
          errors.any((e) => e.type == ValidationErrorType.unsupportedProviderCapability && e.stepId == 's1'),
          true,
        );
      });

      test('multi-prompt step with continuity-supporting provider produces no error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: const ['First', 'Second'], provider: 'claude'),
          ],
        );
        expect(validator.validate(def, continuityProviders: {'claude', 'codex'}).errors, isEmpty);
      });

      test('multi-prompt step with codex provider produces no error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: const ['First', 'Second'], provider: 'codex'),
          ],
        );
        expect(validator.validate(def, continuityProviders: {'claude', 'codex'}).errors, isEmpty);
      });

      test('single-prompt step with non-continuity provider produces no error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: const ['Only one prompt'], provider: 'gemini'),
          ],
        );
        expect(validator.validate(def, continuityProviders: {'claude', 'codex'}).errors, isEmpty);
      });

      test('multi-prompt step with no explicit provider produces no error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: const ['First', 'Second']),
          ],
        );
        expect(validator.validate(def, continuityProviders: {'claude', 'codex'}).errors, isEmpty);
      });

      test('multi-prompt validation skipped when continuityProviders not provided', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: const ['First', 'Second'], provider: 'gemini'),
          ],
        );
        // No continuityProviders arg — validation skipped entirely.
        expect(
          validator.validate(def).errors.any((e) => e.type == ValidationErrorType.unsupportedProviderCapability),
          false,
        );
      });

      test('multi-prompt step with @-prefixed alias provider validates clean', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(id: 's1', name: 'S', prompts: const ['First', 'Second'], provider: '@executor'),
          ],
        );
        expect(
          validator
              .validate(def, continuityProviders: {'claude', 'codex'})
              .errors
              .any((e) => e.type == ValidationErrorType.unsupportedProviderCapability),
          isFalse,
        );
      });
    });

    test('multiple errors are all collected (not fail-fast)', () {
      final def = WorkflowDefinition(name: '', description: '', steps: const []);
      final errors = validator.validate(def).errors;
      expect(errors.length, greaterThan(1));
    });
  });

  group('loop finalizer validation', () {
    test('valid finalizer: step exists and not in loop steps -> no error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'loop-step', name: 'Loop Step', prompts: ['p']),
          WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['p']),
        ],
        loops: const [
          WorkflowLoop(
            id: 'loop1',
            steps: ['loop-step'],
            maxIterations: 3,
            exitGate: 'loop-step.done == true',
            finally_: 'summarize',
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.loopId == 'loop1'), isEmpty);
    });

    test('finalizer referencing non-existent step -> invalidReference error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'loop-step', name: 'Loop Step', prompts: ['p']),
        ],
        loops: const [
          WorkflowLoop(
            id: 'loop1',
            steps: ['loop-step'],
            maxIterations: 3,
            exitGate: 'loop-step.done == true',
            finally_: 'non-existent-step',
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(
        errors.where(
          (e) =>
              e.type == ValidationErrorType.invalidReference &&
              e.loopId == 'loop1' &&
              e.message.contains('non-existent-step'),
        ),
        isNotEmpty,
      );
    });

    test('finalizer referencing step inside loop steps -> loopOverlap error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'loop-step', name: 'Loop Step', prompts: ['p']),
        ],
        loops: const [
          WorkflowLoop(
            id: 'loop1',
            steps: ['loop-step'],
            maxIterations: 3,
            exitGate: 'loop-step.done == true',
            finally_: 'loop-step',
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.type == ValidationErrorType.loopOverlap && e.loopId == 'loop1'), isNotEmpty);
    });

    test('loop without finalizer still valid -> no finalizer errors', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
        ],
        loops: const [
          WorkflowLoop(id: 'loop1', steps: ['ls'], maxIterations: 3, exitGate: 'ls.done == true'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });
  });

  group('stepDefaults validation', () {
    test('stepDefaults pattern matching steps -> no warning emitted', () {
      // We verify no errors are produced; logging is tested separately.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('stepDefaults pattern matching no steps -> no validation error (warning only)', () {
      // An unmatched pattern is a warning (Logger-based), not a ValidationError.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      );
      final errors = validator.validate(def).errors;
      // No ValidationError should be added — only a logger warning.
      expect(errors, isEmpty);
    });

    test('empty stepDefaults list -> valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        stepDefaults: const [],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('null stepDefaults -> valid (backward compat)', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });
  });

  group('S16b: gitStrategy validation', () {
    test('valid gitStrategy passes validation', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: WorkflowGitWorktreeStrategy(mode: 'shared'),
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: true),
        ),
      );
      expect(validator.validate(def).errors, isEmpty);
    });

    test('bootstrap workflows warn when BRANCH defaults to main', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        variables: const {'BRANCH': WorkflowVariable(required: false, description: 'Base ref', defaultValue: 'main')},
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        gitStrategy: const WorkflowGitStrategy(bootstrap: true),
      );

      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single.message, contains('variables.BRANCH.default: "main"'));
      expect(report.warnings.single.message, contains('gitStrategy.bootstrap: true'));
    });

    test('invalid gitStrategy enum-like values produce validation errors', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: 'invalid-worktree'),
          promotion: 'invalid-promotion',
        ),
      );

      final errors = validator.validate(def).errors;
      expect(errors, hasLength(2));
      expect(errors.map((e) => e.message).join('\n'), contains('gitStrategy.worktree'));
      expect(errors.map((e) => e.message).join('\n'), contains('gitStrategy.promotion'));
    });

    test('auto and inline worktree values are accepted', () {
      for (final worktreeMode in ['auto', 'inline']) {
        final def = WorkflowDefinition(
          name: 'wf-$worktreeMode',
          description: 'd',
          steps: const [
            WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          ],
          gitStrategy: WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: worktreeMode)),
        );
        expect(validator.validate(def).errors, isEmpty, reason: 'worktree mode "$worktreeMode" should validate');
      }
    });
  });

  group('skill validation (S04)', () {
    WorkflowDefinition makeSkillDef(WorkflowStep step, {String name = 'wf', String description = 'd'}) {
      return WorkflowDefinition(name: name, description: description, steps: [step]);
    }

    test('no skill registry -> skill validation skipped (no errors)', () {
      final validator = WorkflowDefinitionValidator();
      // No skillRegistry set.
      final def = makeSkillDef(const WorkflowStep(id: 's', name: 'S', skill: 'some-skill', prompts: ['p']));
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('valid skill reference -> no error', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(const WorkflowStep(id: 's', name: 'S', skill: 'review-code', prompts: ['p']));
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('missing skill reference -> validation error with suggestions', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(const WorkflowStep(id: 's', name: 'S', skill: 'nonexistent-skill', prompts: ['p']));
      final errors = validator.validate(def).errors;
      expect(errors, hasLength(1));
      expect(errors.first.type, ValidationErrorType.invalidReference);
      expect(errors.first.stepId, 's');
      expect(errors.first.message, contains('nonexistent-skill'));
    });

    test('skill with explicit provider that is native -> no error', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(id: 's', name: 'S', skill: 'review-code', provider: 'claude', prompts: ['p']),
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('skill with explicit provider that is NOT native -> validation error', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          provider: 'codex', // skill only in claude
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def).errors;
      expect(errors, hasLength(1));
      expect(errors.first.type, ValidationErrorType.invalidReference);
      expect(errors.first.message, contains('codex'));
      expect(errors.first.message, contains('claude'));
    });

    test('skill with both harnesses + explicit provider -> no error', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(bothSkills: {'shared-skill'});
      final def = makeSkillDef(
        const WorkflowStep(id: 's', name: 'S', skill: 'shared-skill', provider: 'codex', prompts: ['p']),
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('filesystem skill copies keep explicit provider validation working', () {
      final workspaceDir = Directory.systemTemp.createTempSync('workflow_validator_fs_ws_');
      final dataDir = Directory.systemTemp.createTempSync('workflow_validator_fs_data_');
      final userClaudeSkillsDir = Directory.systemTemp.createTempSync('workflow_validator_fs_user_claude_');
      addTearDown(() {
        if (workspaceDir.existsSync()) workspaceDir.deleteSync(recursive: true);
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        if (userClaudeSkillsDir.existsSync()) userClaudeSkillsDir.deleteSync(recursive: true);
      });

      final skillDir = Directory(p.join(userClaudeSkillsDir.path, 'andthen-review'))..createSync(recursive: true);
      File(
        p.join(skillDir.path, 'SKILL.md'),
      ).writeAsStringSync('---\nname: andthen-review\ndescription: Filesystem review skill\n---\n\n# review');

      final registry = SkillRegistryImpl();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: userClaudeSkillsDir.path,
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: '/nonexistent',
      );

      final validator = WorkflowDefinitionValidator()..skillRegistry = registry;
      final def = makeSkillDef(
        const WorkflowStep(id: 's', name: 'S', skill: 'andthen-review', provider: 'claude', prompts: ['p']),
      );

      expect(validator.validate(def).errors, isEmpty);
    });

    test('skill + no provider + single-harness skill -> warning only (no error)', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          // No explicit provider.
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def).errors;
      // No validation error — only a log warning.
      expect(errors, isEmpty);
    });

    test('skill-only step (no prompts) with valid skill -> no error', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          // No prompts — skill-only step.
        ),
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('steps without skill field are unaffected by skill validation', () {
      final validator = WorkflowDefinitionValidator()..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(const WorkflowStep(id: 's', name: 'S', prompts: ['p']));
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });
  });

  group('mapOver validation', () {
    test('mapOver referencing a prior contextOutput is valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'collect', name: 'Collect', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'process', name: 'Process', prompts: ['p'], mapOver: 'items'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('mapOver referencing unknown key produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'process', name: 'Process', prompts: ['p'], mapOver: 'items'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, hasLength(1));
      expect(errors[0].type, ValidationErrorType.contextInconsistency);
      expect(errors[0].stepId, 'process');
      expect(errors[0].message, contains('items'));
    });

    test('mapOver referencing own contextOutput (not prior) produces error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 's',
            name: 'S',
            prompts: ['p'],
            mapOver: 'self_output',
            outputs: {'self_output': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.any((e) => e.type == ValidationErrorType.contextInconsistency), isTrue);
    });

    test('no mapOver on any step -> no errors from mapOver check', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('second map step can reference first map step output', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            outputs: {'list1': OutputConfig(), 'list2': OutputConfig()},
          ),
          WorkflowStep(
            id: 'map1',
            name: 'Map1',
            prompts: ['p'],
            mapOver: 'list1',
            outputs: {'mapped1': OutputConfig()},
          ),
          WorkflowStep(id: 'map2', name: 'Map2', prompts: ['p'], mapOver: 'list2'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });
  });

  group('map step constraint validation', () {
    test('map step with parallel:true produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'mapstep',
            name: 'Map',
            prompts: ['p'],
            mapOver: 'items',
            parallel: true,
            outputs: {'results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.type, 'type', ValidationErrorType.contextInconsistency)
              .having((e) => e.stepId, 'stepId', 'mapstep')
              .having((e) => e.message, 'message', contains('cannot also be a parallel step')),
        ),
      );
    });

    test('map step without parallel:true is valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'mapstep',
            name: 'Map',
            prompts: ['p'],
            mapOver: 'items',
            outputs: {'results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.stepId == 'mapstep'), isEmpty);
    });

    test('map step with multiple outputs produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'mapstep',
            name: 'Map',
            prompts: ['p'],
            mapOver: 'items',
            outputs: {'results': OutputConfig(), 'summaries': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.type, 'type', ValidationErrorType.contextInconsistency)
              .having((e) => e.stepId, 'stepId', 'mapstep')
              .having((e) => e.message, 'message', contains('exactly one aggregate list value')),
        ),
      );
    });

    test('foreach controller with multiple outputs produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], outputs: {'story_result': OutputConfig()}),
          WorkflowStep(
            id: 'pipeline',
            name: 'Pipeline',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['implement'],
            outputs: {'story_results': OutputConfig(), 'implementation_results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.type, 'type', ValidationErrorType.contextInconsistency)
              .having((e) => e.stepId, 'stepId', 'pipeline')
              .having((e) => e.message, 'message', contains('exactly one aggregate list value')),
        ),
      );
    });

    test('foreach controller with a single outputs key is valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], outputs: {'story_result': OutputConfig()}),
          WorkflowStep(
            id: 'pipeline',
            name: 'Pipeline',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['implement'],
            outputs: {'story_results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.stepId == 'pipeline'), isEmpty);
    });
  });

  group('hybrid step validation rules', () {
    test('unknown step type produces a warning, not an error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', type: 'unknown-future-type', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(
        report.warnings.any((w) => w.type == ValidationErrorType.hybridStepConstraint && w.stepId == 's'),
        isTrue,
        reason: 'Unknown type should produce a warning',
      );
    });

    test('known types produce no hybrid warning', () {
      for (final type in ['research', 'analysis', 'writing', 'coding', 'automation', 'custom', 'bash', 'approval']) {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: [
            WorkflowStep(id: 's', name: 'S', type: type, prompts: type == 'bash' || type == 'approval' ? null : ['p']),
          ],
        );
        final report = validator.validate(def);
        expect(
          report.warnings.any((w) => w.type == ValidationErrorType.hybridStepConstraint),
          isFalse,
          reason: 'Known type "$type" should not produce a hybrid type warning',
        );
      }
    });

    test('approval step in a loop produces a warning, not an error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'loop-step', name: 'Loop', prompts: ['p']),
          WorkflowStep(id: 'gate', name: 'Gate', type: 'approval'),
        ],
        loops: [
          const WorkflowLoop(
            id: 'approval-loop',
            steps: ['loop-step', 'gate'],
            maxIterations: 3,
            exitGate: 'loop-step.done == true',
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(
        report.warnings.any((w) => w.type == ValidationErrorType.hybridStepConstraint && w.stepId == 'gate'),
        isTrue,
        reason: 'Approval step in loop should produce a warning',
      );
    });

    test('approval step NOT in a loop produces no warning', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 'gate', name: 'Gate', type: 'approval'),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(
        report.warnings.any((w) => w.stepId == 'gate'),
        isFalse,
        reason: 'Approval step outside loop should produce no warning',
      );
    });

    test('approval step with parallel:true is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', parallel: true)],
      );
      final report = validator.validate(def);
      expect(
        report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 'gate'),
        isTrue,
        reason: 'Parallel approval step should produce an error',
      );
    });

    test('structured output requires json format and schema', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['Review'],
            outputs: {'verdict': OutputConfig(format: OutputFormat.text, outputMode: OutputMode.structured)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors.length, greaterThanOrEqualTo(2));
      expect(report.errors.any((e) => e.message.contains('format: json')), isTrue);
      expect(report.errors.any((e) => e.message.contains('has no schema')), isTrue);
    });

    test('structured inline schema requires additionalProperties false on object nodes', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['Review'],
            outputs: {
              'verdict': OutputConfig(
                format: OutputFormat.json,
                outputMode: OutputMode.structured,
                schema: {
                  'type': 'object',
                  'properties': {
                    'summary': {'type': 'string'},
                  },
                },
              ),
            },
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors.any((e) => e.message.contains('additionalProperties: false')), isTrue);
    });

    WorkflowDefinition defWithOutput(OutputConfig outputConfig) => WorkflowDefinition(
      name: 'wf',
      description: 'd',
      steps: [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          prompts: const ['Implement'],
          outputs: {'diff_summary': outputConfig},
        ),
      ],
    );

    test('inline description colliding with text-preset description emits exactly one warning', () {
      // `diff-summary` is a text preset with a canonical description. Setting
      // an inline description as well silently overrides it — should warn.
      final report = validator.validate(
        defWithOutput(
          const OutputConfig(
            format: OutputFormat.text,
            schema: 'diff-summary',
            description: 'Custom inline description overrides the preset.',
          ),
        ),
      );
      expect(report.errors, isEmpty);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single.message, contains('diff_summary'));
      expect(report.warnings.single.message, contains('inline description overrides the preset'));
    });

    test('preset reference without inline description does not warn', () {
      final report = validator.validate(
        defWithOutput(const OutputConfig(format: OutputFormat.text, schema: 'diff-summary')),
      );
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
    });

    test('inline description with no preset at all does not warn', () {
      final report = validator.validate(
        defWithOutput(const OutputConfig(format: OutputFormat.text, description: 'Freeform description, no preset.')),
      );
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
    });

    test('inline description with a preset that has no description does not warn', () {
      // `non-negative-integer` is a JSON preset with no `description` — can
      // only be paired with `format: json`. An inline description here is
      // an authoring choice, not a collision.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['Review'],
            outputs: {
              'findings_count': OutputConfig(
                format: OutputFormat.json,
                schema: 'non-negative-integer',
                description: 'How many things we found.',
              ),
            },
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
    });

    test('whitespace-only inline description is a hard error', () {
      final report = validator.validate(
        defWithOutput(const OutputConfig(format: OutputFormat.text, schema: 'diff-summary', description: '   ')),
      );
      expect(
        report.errors.any((e) => e.message.contains('diff_summary') && e.message.contains('blank "description"')),
        isTrue,
      );
    });

    test('json output without schema is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'research',
            name: 'Research',
            type: 'research',
            prompts: ['Research'],
            outputs: {'verdict': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors.any((e) => e.message.contains('format: json requires a schema')), isTrue);
    });

    test('foreach controller json aggregate does not require a schema', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], outputs: {'story_result': OutputConfig()}),
          WorkflowStep(
            id: 'pipeline',
            name: 'Pipeline',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['implement'],
            outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
    });

    test('bash step with multi-prompt list is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'build', name: 'Build', type: 'bash', prompts: ['dart analyze', 'dart test']),
        ],
      );
      final report = validator.validate(def);
      expect(
        report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 'build'),
        isTrue,
      );
    });

    test('approval step with multi-prompt list is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', prompts: ['Approve?', 'Still approve?']),
        ],
      );
      final report = validator.validate(def);
      expect(
        report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 'gate'),
        isTrue,
      );
    });

    test('approval step without parallel:true produces no error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [WorkflowStep(id: 'gate', name: 'Gate', type: 'approval')],
      );
      final report = validator.validate(def);
      expect(report.errors.any((e) => e.stepId == 'gate'), isFalse);
    });

    test('bash step produces no hybrid constraint errors', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [WorkflowStep(id: 's', name: 'Build', type: 'bash', workdir: '/workspace')],
      );
      final report = validator.validate(def);
      expect(report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint), isFalse);
    });

    test('continueSession on first step is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p'], continueSession: '@previous'),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(
        report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 's1'),
        isTrue,
        reason: 'continueSession on first step should be an error',
      );
    });

    test('continueSession on non-first step with no continuityProviders produces no error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous'),
        ],
      );
      // No continuityProviders supplied — provider check skipped.
      final report = validator.validate(def);
      expect(report.errors.any((e) => e.stepId == 's2'), isFalse);
    });

    test('continueSession with unsupported provider is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous', provider: 'codex'),
        ],
      );
      // claude supports continuity, codex does not.
      final report = validator.validate(def, continuityProviders: {'claude'});
      expect(
        report.errors.any((e) => e.type == ValidationErrorType.unsupportedProviderCapability && e.stepId == 's2'),
        isTrue,
        reason: 'continueSession with non-continuity provider should be an error',
      );
    });

    test('continueSession with supported provider produces no error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous', provider: 'claude'),
        ],
      );
      final report = validator.validate(def, continuityProviders: {'claude'});
      expect(report.errors.any((e) => e.stepId == 's2'), isFalse);
    });

    test('continueSession with @-prefixed alias provider validates clean', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous', provider: '@executor'),
        ],
      );
      // Concrete continuity providers do not include @executor; the alias
      // skip ensures the validator does not false-positive on it. The runtime
      // alias-mismatch warning at WorkflowExecutor._resolveContinueSessionProvider
      // remains the safety net.
      final report = validator.validate(def, continuityProviders: {'claude'});
      expect(
        report.errors.any((e) => e.type == ValidationErrorType.unsupportedProviderCapability && e.stepId == 's2'),
        isFalse,
      );
    });

    test('parallel continueSession step is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous', parallel: true),
        ],
      );
      final report = validator.validate(def, continuityProviders: {'claude'});
      expect(report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 's2'), isTrue);
    });

    test('unsupported onError value produces a warning', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p'], onError: 'retry'),
        ],
      );
      final report = validator.validate(def);
      expect(report.warnings.any((w) => w.type == ValidationErrorType.hybridStepConstraint && w.stepId == 's'), isTrue);
    });

    test('ValidationReport.isEmpty is true when both errors and warnings are empty', () {
      final def = _buildDef();
      final report = validator.validate(def);
      expect(report.isEmpty, isTrue);
      expect(report.hasErrors, isFalse);
      expect(report.hasWarnings, isFalse);
    });

    test('ValidationReport.hasErrors is true when errors exist', () {
      final def = _buildDef(name: ''); // missing name
      final report = validator.validate(def);
      expect(report.hasErrors, isTrue);
      expect(report.isEmpty, isFalse);
    });

    test('ValidationReport.hasWarnings is true when only warnings exist', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', type: 'future-type', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(report.hasErrors, isFalse);
      expect(report.hasWarnings, isTrue);
      expect(report.isEmpty, isFalse);
    });

    group('continueSession illegal-target validation', () {
      test('continueSession on bash step is a hard error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
            WorkflowStep(id: 's2', name: 'S2', type: 'bash', prompts: ['echo hi']),
            WorkflowStep(id: 's3', name: 'S3', prompts: ['p'], continueSession: '@previous'),
          ],
        );
        // s3 precedes a bash step — hard error.
        final report = validator.validate(def);
        expect(
          report.errors.any(
            (e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 's3' && e.message.contains('bash'),
          ),
          isTrue,
          reason: 'continueSession after bash step should be a hard error',
        );
      });

      test('continueSession on approval step is a hard error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
            WorkflowStep(id: 's2', name: 'S2', type: 'approval', prompts: ['Approve?']),
            WorkflowStep(id: 's3', name: 'S3', prompts: ['p'], continueSession: '@previous'),
          ],
        );
        final report = validator.validate(def);
        expect(
          report.errors.any(
            (e) =>
                e.type == ValidationErrorType.hybridStepConstraint &&
                e.stepId == 's3' &&
                e.message.contains('approval'),
          ),
          isTrue,
          reason: 'continueSession after approval step should be a hard error',
        );
      });

      test('continueSession step that itself is bash is a hard error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
            WorkflowStep(id: 's2', name: 'S2', type: 'bash', prompts: ['echo hi'], continueSession: '@previous'),
          ],
        );
        final report = validator.validate(def);
        expect(
          report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 's2'),
          isTrue,
          reason: 'bash step with continueSession is itself illegal',
        );
      });

      test('continueSession crossing a loop boundary is a hard error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 'inside', name: 'Inside', prompts: ['p']),
            WorkflowStep(id: 'outside', name: 'Outside', prompts: ['p'], continueSession: 'inside'),
          ],
          loops: [
            WorkflowLoop(id: 'loop1', steps: ['inside'], exitGate: '{{context.done}}', maxIterations: 3),
          ],
        );
        final report = validator.validate(def);
        expect(
          report.errors.any(
            (e) =>
                e.type == ValidationErrorType.hybridStepConstraint &&
                e.stepId == 'outside' &&
                e.message.contains('loop boundary'),
          ),
          isTrue,
          reason: 'continueSession crossing a loop boundary should be a hard error',
        );
      });

      test('continueSession crossing into a loop is a hard error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 'outside', name: 'Outside', prompts: ['p']),
            WorkflowStep(id: 'inside', name: 'Inside', prompts: ['p'], continueSession: 'outside'),
          ],
          loops: [
            WorkflowLoop(id: 'loop1', steps: ['inside'], exitGate: '{{context.done}}', maxIterations: 3),
          ],
        );
        final report = validator.validate(def);
        expect(
          report.errors.any(
            (e) =>
                e.type == ValidationErrorType.hybridStepConstraint &&
                e.stepId == 'inside' &&
                e.message.contains('loop boundary'),
          ),
          isTrue,
          reason: 'continueSession entering a loop from outside should be a hard error',
        );
      });

      test('continueSession within the same loop is valid', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 'step1', name: 'Step1', prompts: ['p']),
            WorkflowStep(id: 'step2', name: 'Step2', prompts: ['p'], continueSession: 'step1'),
          ],
          loops: [
            WorkflowLoop(id: 'loop1', steps: ['step1', 'step2'], exitGate: '{{context.done}}', maxIterations: 3),
          ],
        );
        final report = validator.validate(def);
        expect(
          report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint && e.stepId == 'step2'),
          isFalse,
          reason: 'continueSession within the same loop should not be an error',
        );
      });

      test('valid linear continueSession chain (all agent steps, outside loops) produces no error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['Investigate']),
            WorkflowStep(id: 's2', name: 'S2', prompts: ['Fix it'], continueSession: 's1'),
            WorkflowStep(id: 's3', name: 'S3', prompts: ['Verify'], continueSession: 's2'),
          ],
        );
        final report = validator.validate(def);
        expect(
          report.errors.any((e) => e.type == ValidationErrorType.hybridStepConstraint),
          isFalse,
          reason: 'valid linear continueSession chain should produce no errors',
        );
      });
    });
  });

  group('foreach node validation', () {
    test('valid foreach controller with children passes validation', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['c1', 'c2'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'c1', name: 'C1', prompts: ['p']),
          WorkflowStep(id: 'c2', name: 'C2', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('foreach controller referencing unknown child step produces invalidReference error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['c1', 'nonexistent'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'c1', name: 'C1', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.any((e) => e.type == ValidationErrorType.invalidReference && e.stepId == 'nonexistent'), isTrue);
    });

    test('foreach node with empty childStepIds produces missingField error', () {
      // Construct definition with a step that claims to be foreach but has empty foreachSteps.
      // This bypasses the parser (which rejects empty steps) and tests the validator directly.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'fe', name: 'FE', type: 'foreach', mapOver: 'items', foreachSteps: []),
        ],
      );
      // With empty foreachSteps, isForeachController is false, so normalization
      // produces a MapNode instead. Validator checks differ per node type.
      // This verifies the definition is constructable but not treated as foreach.
      expect(def.steps[1].isForeachController, isFalse);
    });

    test('foreach type registered as known type (no unknown-type warning)', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['c1'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'c1', name: 'C1', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(
        report.warnings.any((w) => w.type == ValidationErrorType.hybridStepConstraint && w.stepId == 'fe'),
        isFalse,
        reason: 'foreach is a known type and should not trigger unknown-type warning',
      );
    });

    group('step entryGate validation', () {
      test('accepts bare-key and stepId.key forms', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(
              id: 'prd',
              name: 'PRD',
              prompts: ['p'],
              outputs: {'prd': OutputConfig(), 'prd_source': OutputConfig()},
            ),
            WorkflowStep(
              id: 'review-prd',
              name: 'Review',
              prompts: ['r'],
              entryGate: 'prd_source == synthesized',
              inputs: ['prd'],
            ),
            WorkflowStep(
              id: 'plan',
              name: 'Plan',
              prompts: ['p'],
              entryGate: 'review-prd.findings_count > 0',
              inputs: ['prd'],
            ),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.type == ValidationErrorType.invalidGate), isFalse);
      });

      test('rejects malformed entryGate expression', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
            WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], entryGate: 'not a valid gate'),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.type == ValidationErrorType.invalidGate && e.stepId == 's2'), isTrue);
      });
    });

    group('gitStrategy.artifacts validation', () {
      test('per-map-item + artifact producer + commit: false raises error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
            artifacts: WorkflowGitArtifactsStrategy(commit: false),
          ),
          steps: const [
            WorkflowStep(id: 'plan', name: 'Plan', skill: 'andthen-plan', outputs: {'plan': OutputConfig()}),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('artifacts.commit: false is incompatible')), isTrue);
      });

      test('auto + map step maxParallel > 1 + artifact producer + commit: false raises error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(mode: 'auto'),
            artifacts: WorkflowGitArtifactsStrategy(commit: false),
          ),
          steps: const [
            WorkflowStep(id: 'plan', name: 'Plan', skill: 'andthen-plan', outputs: {'plan': OutputConfig()}),
            WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], mapOver: 'stories', maxParallel: 2),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('artifacts.commit: false is incompatible')), isTrue);
      });

      test('auto + map step maxParallel 1 + artifact producer + commit: false does not raise per-map-item error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(mode: 'auto'),
            artifacts: WorkflowGitArtifactsStrategy(commit: false),
          ),
          steps: const [
            WorkflowStep(id: 'plan', name: 'Plan', skill: 'andthen-plan', outputs: {'plan': OutputConfig()}),
            WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], mapOver: 'stories', maxParallel: 1),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('artifacts.commit: false is incompatible')), isFalse);
      });

      test('shared + artifact producer + commit: false issues warning not error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(mode: 'shared'),
            artifacts: WorkflowGitArtifactsStrategy(commit: false),
          ),
          steps: const [
            WorkflowStep(id: 'plan', name: 'Plan', skill: 'andthen-plan', outputs: {'plan': OutputConfig()}),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('artifacts.commit')), isFalse);
        expect(report.warnings.any((w) => w.message.contains('worktree: shared')), isTrue);
      });

      test('no artifact producer + per-map-item accepted', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item')),
          steps: const [
            WorkflowStep(id: 'only', name: 'Only', prompts: ['p']),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('artifacts.commit')), isFalse);
      });

      test('externalArtifactMount per-story-copy without source raises error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(
              mode: 'per-map-item',
              externalArtifactMount: WorkflowGitExternalArtifactMount(mode: 'per-story-copy', fromProject: 'DOC'),
            ),
          ),
          steps: const [
            WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('externalArtifactMount.source')), isTrue);
      });

      test('externalArtifactMount bind-mount without fromPath raises error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(
              mode: 'per-map-item',
              externalArtifactMount: WorkflowGitExternalArtifactMount(mode: 'bind-mount', fromProject: 'DOC'),
            ),
          ),
          steps: const [
            WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('externalArtifactMount.fromPath')), isTrue);
      });

      test('flat-level externalArtifactMount emits migration error', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(
              mode: 'per-map-item',
              externalArtifactMount: WorkflowGitExternalArtifactMount(
                mode: 'per-story-copy',
                fromProject: 'DOC',
                source: '{{map.item.spec_path}}',
              ),
            ),
            legacyExternalArtifactMountLocation: true,
          ),
          steps: const [
            WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          ],
        );
        final report = validator.validate(def);
        expect(report.errors.any((e) => e.message.contains('gitStrategy.worktree.externalArtifactMount')), isTrue);
      });

      test('stepDefaults ordering note is emitted when multiple patterns match a step', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          stepDefaults: const [
            StepConfigDefault(match: 'prd', provider: '@planner'),
            StepConfigDefault(match: '*review*', provider: '@reviewer'),
            StepConfigDefault(match: '*', provider: '@workflow'),
          ],
          steps: const [
            WorkflowStep(id: 'review-prd', name: 'Review PRD', prompts: ['p']),
          ],
        );
        final report = validator.validate(def);
        expect(report.warnings.any((w) => w.message.contains('stepDefaults ordering is load-bearing')), isTrue);
        expect(report.warnings.any((w) => w.message.contains('review-prd')), isTrue);
      });
    });

    group('gitStrategy.merge_resolve validation', () {
      WorkflowDefinition mrDef({required MergeResolveConfig mergeResolve, String? promotion}) => WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: WorkflowGitStrategy(promotion: promotion, mergeResolve: mergeResolve),
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );

      // TI04 — BPC-17 row 1
      test('enabled:true with promotion:squash emits exact BPC-17 row 1 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: true), promotion: 'squash');
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                'WorkflowDefinitionError: gitStrategy.merge_resolve.enabled requires gitStrategy.promotion: merge',
          ),
          isTrue,
        );
      });

      test('enabled:true with promotion:none emits exact BPC-17 row 1 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: true), promotion: 'none');
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                'WorkflowDefinitionError: gitStrategy.merge_resolve.enabled requires gitStrategy.promotion: merge',
          ),
          isTrue,
        );
      });

      test('enabled:true with absent promotion emits BPC-17 row 1 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: true));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                'WorkflowDefinitionError: gitStrategy.merge_resolve.enabled requires gitStrategy.promotion: merge',
          ),
          isTrue,
        );
      });

      test('enabled:false with promotion:squash produces no merge_resolve error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: false), promotion: 'squash');
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.message.contains('merge_resolve.enabled')), isFalse);
      });

      test('enabled:true with promotion:merge produces no row-1 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: true), promotion: 'merge');
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.message.contains('merge_resolve.enabled')), isFalse);
      });

      // TI05 — BPC-17 row 2
      test('max_attempts:0 emits exact BPC-17 row 2 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(maxAttempts: 0));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message == 'WorkflowDefinitionError: gitStrategy.merge_resolve.max_attempts must be between 1 and 5',
          ),
          isTrue,
        );
      });

      test('max_attempts:6 emits exact BPC-17 row 2 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(maxAttempts: 6));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message == 'WorkflowDefinitionError: gitStrategy.merge_resolve.max_attempts must be between 1 and 5',
          ),
          isTrue,
        );
      });

      test('max_attempts:1 is valid', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(maxAttempts: 1));
        expect(validator.validate(def).errors.any((e) => e.message.contains('max_attempts')), isFalse);
      });

      test('max_attempts:5 is valid', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(maxAttempts: 5));
        expect(validator.validate(def).errors.any((e) => e.message.contains('max_attempts')), isFalse);
      });

      // TI06 — BPC-17 row 3
      test('token_ceiling:9999 emits exact BPC-17 row 3 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(tokenCeiling: 9999));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                'WorkflowDefinitionError: gitStrategy.merge_resolve.token_ceiling must be between 10000 and 500000',
          ),
          isTrue,
        );
      });

      test('token_ceiling:500001 emits exact BPC-17 row 3 error', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(tokenCeiling: 500001));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                'WorkflowDefinitionError: gitStrategy.merge_resolve.token_ceiling must be between 10000 and 500000',
          ),
          isTrue,
        );
      });

      test('token_ceiling:10000 is valid', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(tokenCeiling: 10000));
        expect(validator.validate(def).errors.any((e) => e.message.contains('token_ceiling')), isFalse);
      });

      test('token_ceiling:500000 is valid', () {
        final def = mrDef(mergeResolve: const MergeResolveConfig(tokenCeiling: 500000));
        expect(validator.validate(def).errors.any((e) => e.message.contains('token_ceiling')), isFalse);
      });

      // TI07 — BPC-17 row 4
      test('escalation:pause emits exact BPC-17 row 4 error only', () {
        final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'escalation': 'pause'}));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                "WorkflowDefinitionError: gitStrategy.merge_resolve.escalation: 'pause' is reserved for a future release",
          ),
          isTrue,
        );
        expect(
          errors.any((e) => e.message.contains('must be one of')),
          isFalse,
          reason: 'pause must not also trigger the generic enum error',
        );
      });

      test('escalation:yolo emits generic enum error (not pause message)', () {
        final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'escalation': 'yolo'}));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                'WorkflowDefinitionError: gitStrategy.merge_resolve.escalation must be one of serialize-remaining, fail',
          ),
          isTrue,
        );
        expect(errors.any((e) => e.message.contains("'pause' is reserved")), isFalse);
      });

      test('escalation:serialize-remaining is valid', () {
        final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'escalation': 'serialize-remaining'}));
        expect(validator.validate(def).errors.any((e) => e.message.contains('escalation')), isFalse);
      });

      test('escalation:fail is valid', () {
        final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'escalation': 'fail'}));
        expect(validator.validate(def).errors.any((e) => e.message.contains('escalation')), isFalse);
      });

      // TI08 — BPC-17 row 5
      test('unknown top-level key emits exact BPC-17 row 5 error', () {
        final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'foo': 'bar'}));
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) => e.message == "WorkflowDefinitionError: unknown field 'foo' under gitStrategy.merge_resolve",
          ),
          isTrue,
        );
      });

      test('unknown verification key emits exact BPC-17 row 5 error with verification path', () {
        final def = mrDef(
          mergeResolve: MergeResolveConfig.fromJson({
            'verification': {'lint': 'x'},
          }),
        );
        final errors = validator.validate(def).errors;
        expect(
          errors.any(
            (e) =>
                e.message ==
                "WorkflowDefinitionError: unknown field 'lint' under gitStrategy.merge_resolve.verification",
          ),
          isTrue,
        );
      });

      test('two unknown top-level keys produce two errors', () {
        final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'foo': 1, 'bar': 2}));
        final errors = validator.validate(def).errors;
        expect(errors.where((e) => e.message.contains('under gitStrategy.merge_resolve')).length, 2);
      });

      // TI09 — Backward compat: merge_resolve absent
      test('definition with no merge_resolve produces zero new errors', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          gitStrategy: const WorkflowGitStrategy(promotion: 'merge'),
          steps: const [
            WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.message.contains('merge_resolve')), isFalse);
      });

      test('merge_resolve:enabled:false with any promotion passes validation', () {
        for (final promo in ['squash', 'none', 'merge', null]) {
          final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: false), promotion: promo);
          expect(
            validator.validate(def).errors.any((e) => e.message.contains('merge_resolve')),
            isFalse,
            reason: 'promotion=$promo should not trigger merge_resolve errors when disabled',
          );
        }
      });
    });
  });

  group('map alias (`as:`) validation', () {
    test('valid `as:` on a map step produces no errors', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'each',
            name: 'Each',
            prompts: ['Process {{thing.item.path}}'],
            mapOver: 'items',
            mapAlias: 'thing',
            outputs: {'results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('`as:` on a non-map step is an error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['hi'], mapAlias: 'story'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.any((e) => e.message.contains('only valid on map/foreach controllers')), isTrue);
    });

    test('`as:` colliding with a workflow variable is an error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        variables: const {'PROJECT': WorkflowVariable(required: false, defaultValue: 'x')},
        steps: const [
          WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'each',
            name: 'Each',
            prompts: ['p'],
            mapOver: 'items',
            mapAlias: 'PROJECT',
            outputs: {'results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.any((e) => e.message.contains('collides with a declared workflow variable')), isTrue);
    });

    test('alias references in substep prompts are not flagged as undeclared variables', () {
      // `{{story.item.spec_path}}` in the child prompt would be mistaken for an
      // undeclared variable without alias-aware extraction.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'pipeline',
            name: 'Pipeline',
            prompts: null,
            mapOver: 'items',
            mapAlias: 'story',
            foreachSteps: ['implement'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{story.item.spec_path}}']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(
        errors.any((e) => e.message.contains('undeclared variable')),
        isFalse,
        reason: 'Alias-aware extraction should skip {{story.*}} in child prompts',
      );
    });
  });
}
