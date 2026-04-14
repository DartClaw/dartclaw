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
  List<String> contextInputs = const [],
  List<String> contextOutputs = const [],
  String? gate,
}) => WorkflowStep(
  id: id,
  name: name,
  prompts: [prompt],
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
              contextInputs: ['items'],
              contextOutputs: ['mapped'],
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
    });

    group('context key consistency', () {
      test('context input referencing key not in preceding step outputs produces contextInconsistency', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', contextInputs: ['key_a'], contextOutputs: []),
          ],
        );
        final errors = validator.validate(def).errors;
        expect(errors.any((e) => e.type == ValidationErrorType.contextInconsistency), true);
      });

      test('context input valid when preceding step declares the output', () {
        final def = _buildDef(
          steps: [
            _step(id: 's1', contextOutputs: ['result']),
            _step(id: 's2', name: 'S2', prompt: 'p', contextInputs: ['result']),
          ],
        );
        expect(validator.validate(def).errors, isEmpty);
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
        expect(validator.validate(def).errors, isEmpty);
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
            _step(id: 's1', contextOutputs: ['status', 'score']),
            _step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status == done && s1.score >= 90'),
          ],
        );
        expect(validator.validate(def).errors, isEmpty);
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
    });

    test('multiple errors are all collected (not fail-fast)', () {
      final def = WorkflowDefinition(name: '', description: '', steps: const []);
      final errors = validator.validate(def).errors;
      expect(errors.length, greaterThan(1));
    });
  });

  group('S03: loop finalizer validation', () {
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

  group('S03: stepDefaults validation', () {
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

      final skillDir = Directory(p.join(userClaudeSkillsDir.path, 'dartclaw-review-code'))..createSync(recursive: true);
      File(
        p.join(skillDir.path, 'SKILL.md'),
      ).writeAsStringSync('---\nname: dartclaw-review-code\ndescription: Filesystem review skill\n---\n\n# review');

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
        const WorkflowStep(id: 's', name: 'S', skill: 'dartclaw-review-code', provider: 'claude', prompts: ['p']),
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

  group('S06: mapOver validation', () {
    test('mapOver referencing a prior contextOutput is valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'collect', name: 'Collect', prompts: ['p'], contextOutputs: ['items']),
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
          WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'self_output', contextOutputs: ['self_output']),
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
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['list1', 'list2']),
          WorkflowStep(id: 'map1', name: 'Map1', prompts: ['p'], mapOver: 'list1', contextOutputs: ['mapped1']),
          WorkflowStep(id: 'map2', name: 'Map2', prompts: ['p'], mapOver: 'list2'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });
  });

  group('S07: map step constraint validation', () {
    test('map step with parallel:true produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'mapstep',
            name: 'Map',
            prompts: ['p'],
            mapOver: 'items',
            parallel: true,
            contextOutputs: ['results'],
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
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(id: 'mapstep', name: 'Map', prompts: ['p'], mapOver: 'items', contextOutputs: ['results']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.stepId == 'mapstep'), isEmpty);
    });
  });

  group('S01 (0.16.1): hybrid step validation rules', () {
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

    group('S04 (0.16.1): continueSession illegal-target validation', () {
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
}
