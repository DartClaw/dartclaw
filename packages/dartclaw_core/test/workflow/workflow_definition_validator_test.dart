import 'package:dartclaw_core/dartclaw_core.dart';
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
      source: SkillSource.projectCodex,
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
}) {
  return WorkflowDefinition(
    name: name,
    description: description,
    variables: variables,
    steps: steps.isEmpty
        ? [const WorkflowStep(id: 's1', name: 'S1', prompts: ['Do it'])]
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
              prompts: ['p'],
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

    group('multi-prompt provider validation (S02)', () {
      test('multi-prompt step with non-continuity provider produces unsupportedProviderCapability error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(
              id: 's1',
              name: 'S',
              prompts: const ['First', 'Second'],
              provider: 'codex',
            ),
          ],
        );
        final errors = validator.validate(def, continuityProviders: {'claude'});
        expect(
          errors.any((e) => e.type == ValidationErrorType.unsupportedProviderCapability && e.stepId == 's1'),
          true,
        );
      });

      test('multi-prompt step with continuity-supporting provider produces no error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(
              id: 's1',
              name: 'S',
              prompts: const ['First', 'Second'],
              provider: 'claude',
            ),
          ],
        );
        expect(validator.validate(def, continuityProviders: {'claude'}), isEmpty);
      });

      test('single-prompt step with non-continuity provider produces no error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(
              id: 's1',
              name: 'S',
              prompts: const ['Only one prompt'],
              provider: 'codex',
            ),
          ],
        );
        expect(validator.validate(def, continuityProviders: {'claude'}), isEmpty);
      });

      test('multi-prompt step with no explicit provider produces no error', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(
              id: 's1',
              name: 'S',
              prompts: const ['First', 'Second'],
            ),
          ],
        );
        expect(validator.validate(def, continuityProviders: {'claude'}), isEmpty);
      });

      test('multi-prompt validation skipped when continuityProviders not provided', () {
        final def = _buildDef(
          steps: [
            WorkflowStep(
              id: 's1',
              name: 'S',
              prompts: const ['First', 'Second'],
              provider: 'codex',
            ),
          ],
        );
        // No continuityProviders arg — validation skipped entirely.
        expect(
          validator.validate(def).any((e) => e.type == ValidationErrorType.unsupportedProviderCapability),
          false,
        );
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
      final errors = validator.validate(def);
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
      final errors = validator.validate(def);
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
      final errors = validator.validate(def);
      expect(
        errors.where(
          (e) =>
              e.type == ValidationErrorType.loopOverlap &&
              e.loopId == 'loop1',
        ),
        isNotEmpty,
      );
    });

    test('loop without finalizer still valid -> no finalizer errors', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
        ],
        loops: const [
          WorkflowLoop(
            id: 'loop1',
            steps: ['ls'],
            maxIterations: 3,
            exitGate: 'ls.done == true',
          ),
        ],
      );
      final errors = validator.validate(def);
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
        stepDefaults: const [
          StepConfigDefault(match: 'review*', model: 'claude-opus-4'),
        ],
      );
      final errors = validator.validate(def);
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
        stepDefaults: const [
          StepConfigDefault(match: 'review*', model: 'claude-opus-4'),
        ],
      );
      final errors = validator.validate(def);
      // No ValidationError should be added — only a logger warning.
      expect(errors, isEmpty);
    });

    test('empty stepDefaults list -> valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [WorkflowStep(id: 's', name: 'S', prompts: ['p'])],
        stepDefaults: const [],
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });

    test('null stepDefaults -> valid (backward compat)', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [WorkflowStep(id: 's', name: 'S', prompts: ['p'])],
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });
  });

  group('skill validation (S04)', () {
    WorkflowDefinition makeSkillDef(
      WorkflowStep step, {
      String name = 'wf',
      String description = 'd',
    }) {
      return WorkflowDefinition(
        name: name,
        description: description,
        steps: [step],
      );
    }

    test('no skill registry -> skill validation skipped (no errors)', () {
      final validator = WorkflowDefinitionValidator();
      // No skillRegistry set.
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'some-skill',
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });

    test('valid skill reference -> no error', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });

    test('missing skill reference -> validation error with suggestions', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'nonexistent-skill',
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def);
      expect(errors, hasLength(1));
      expect(errors.first.type, ValidationErrorType.invalidReference);
      expect(errors.first.stepId, 's');
      expect(errors.first.message, contains('nonexistent-skill'));
    });

    test('skill with explicit provider that is native -> no error', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          provider: 'claude',
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });

    test('skill with explicit provider that is NOT native -> validation error', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          provider: 'codex', // skill only in claude
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def);
      expect(errors, hasLength(1));
      expect(errors.first.type, ValidationErrorType.invalidReference);
      expect(errors.first.message, contains('codex'));
      expect(errors.first.message, contains('claude'));
    });

    test('skill with both harnesses + explicit provider -> no error', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(bothSkills: {'shared-skill'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'shared-skill',
          provider: 'codex',
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });

    test('skill + no provider + single-harness skill -> warning only (no error)', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          // No explicit provider.
          prompts: ['p'],
        ),
      );
      final errors = validator.validate(def);
      // No validation error — only a log warning.
      expect(errors, isEmpty);
    });

    test('skill-only step (no prompts) with valid skill -> no error', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(
          id: 's',
          name: 'S',
          skill: 'review-code',
          // No prompts — skill-only step.
        ),
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });

    test('steps without skill field are unaffected by skill validation', () {
      final validator = WorkflowDefinitionValidator()
        ..skillRegistry = _makeRegistry(claudeSkills: {'review-code'});
      final def = makeSkillDef(
        const WorkflowStep(id: 's', name: 'S', prompts: ['p']),
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });
  });

  group('S06: mapOver validation', () {
    test('mapOver referencing a prior contextOutput is valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'collect',
            name: 'Collect',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'process',
            name: 'Process',
            prompts: ['p'],
            mapOver: 'items',
          ),
        ],
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });

    test('mapOver referencing unknown key produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'process',
            name: 'Process',
            prompts: ['p'],
            mapOver: 'items',
          ),
        ],
      );
      final errors = validator.validate(def);
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
            contextOutputs: ['self_output'],
          ),
        ],
      );
      final errors = validator.validate(def);
      expect(
        errors.any((e) => e.type == ValidationErrorType.contextInconsistency),
        isTrue,
      );
    });

    test('no mapOver on any step -> no errors from mapOver check', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def);
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
            contextOutputs: ['list1', 'list2'],
          ),
          WorkflowStep(
            id: 'map1',
            name: 'Map1',
            prompts: ['p'],
            mapOver: 'list1',
            contextOutputs: ['mapped1'],
          ),
          WorkflowStep(
            id: 'map2',
            name: 'Map2',
            prompts: ['p'],
            mapOver: 'list2',
          ),
        ],
      );
      final errors = validator.validate(def);
      expect(errors, isEmpty);
    });
  });

  group('S07: map step constraint validation', () {
    test('map step with parallel:true produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
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
      final errors = validator.validate(def);
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
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'mapstep',
            name: 'Map',
            prompts: ['p'],
            mapOver: 'items',
            contextOutputs: ['results'],
          ),
        ],
      );
      final errors = validator.validate(def);
      expect(
        errors.where((e) => e.stepId == 'mapstep'),
        isEmpty,
      );
    });
  });
}
