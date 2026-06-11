import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  group('Codex allowedTools policy warnings', () {
    test('returns one warning per non-read-only Codex allowedTools step', () async {
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger('WorkflowDefinitionValidator').onRecord.listen(records.add);
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = previousLevel;
      });
      final codexValidator = WorkflowDefinitionValidator(
        roleDefaults: const WorkflowRoleDefaults(executor: WorkflowRoleDefault(provider: 'codex')),
      );
      final def = buildDef(
        name: 'codex-policy',
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            provider: '@executor',
            allowedTools: ['shell', 'file_read', 'file_write'],
            prompts: ['p'],
          ),
        ],
      );

      final first = codexValidator.validate(def);
      final second = codexValidator.validate(def);
      await pumpEventQueue();

      expect(first.warnings, hasLength(1));
      expect(second.warnings, hasLength(1));
      final warnings = records.where((record) => record.level == Level.WARNING).toList();
      expect(warnings, isEmpty);
    });

    test('does not warn for read-only Codex allowedTools', () {
      final codexValidator = WorkflowDefinitionValidator(
        roleDefaults: const WorkflowRoleDefaults(executor: WorkflowRoleDefault(provider: 'codex')),
      );
      final def = buildDef(
        steps: const [
          WorkflowStep(
            id: 'inspect',
            name: 'Inspect',
            provider: '@executor',
            allowedTools: ['shell', 'file_read'],
            prompts: ['p'],
          ),
        ],
      );

      final report = codexValidator.validate(def);

      expect(
        report.warnings.where((warning) => warning.message.contains('Codex CLI has no native tool allowlist')),
        isEmpty,
      );
    });
  });

  group('multi-prompt provider validation (S02)', () {
    final cases = [
      (
        name: 'multi-prompt non-continuity provider',
        provider: 'gemini',
        prompts: const ['First', 'Second'],
        continuityProviders: {'claude', 'codex'},
        expectedError: ValidationErrorType.unsupportedProviderCapability,
      ),
      (
        name: 'multi-prompt continuity provider',
        provider: 'claude',
        prompts: const ['First', 'Second'],
        continuityProviders: {'claude', 'codex'},
        expectedError: null,
      ),
      (
        name: 'multi-prompt codex provider',
        provider: 'codex',
        prompts: const ['First', 'Second'],
        continuityProviders: {'claude', 'codex'},
        expectedError: null,
      ),
      (
        name: 'single-prompt non-continuity provider',
        provider: 'gemini',
        prompts: const ['Only one prompt'],
        continuityProviders: {'claude', 'codex'},
        expectedError: null,
      ),
      (
        name: 'single-prompt unknown alias provider',
        provider: '@executer',
        prompts: const ['Only one prompt'],
        continuityProviders: {'claude', 'codex'},
        expectedError: ValidationErrorType.invalidReference,
      ),
      (
        name: 'multi-prompt no explicit provider',
        provider: null,
        prompts: const ['First', 'Second'],
        continuityProviders: {'claude', 'codex'},
        expectedError: null,
      ),
      (
        name: 'multi-prompt validation skipped without continuityProviders',
        provider: 'gemini',
        prompts: const ['First', 'Second'],
        continuityProviders: null,
        expectedError: null,
      ),
      (
        name: 'multi-prompt alias provider',
        provider: '@executor',
        prompts: const ['First', 'Second'],
        continuityProviders: {'claude', 'codex'},
        expectedError: null,
      ),
      (
        name: 'multi-prompt unknown alias provider',
        provider: '@executer',
        prompts: const ['First', 'Second'],
        continuityProviders: {'claude', 'codex'},
        expectedError: ValidationErrorType.invalidReference,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final def = buildDef(
          steps: [WorkflowStep(id: 's1', name: 'S', prompts: testCase.prompts, provider: testCase.provider)],
        );
        final errors = testCase.continuityProviders == null
            ? validator.validate(def).errors
            : validator.validate(def, continuityProviders: testCase.continuityProviders).errors;

        if (testCase.expectedError == null) {
          expect(hasError(errors, type: ValidationErrorType.unsupportedProviderCapability), isFalse);
          expect(hasError(errors, type: ValidationErrorType.invalidReference), isFalse);
        } else {
          expect(hasError(errors, type: testCase.expectedError, stepId: 's1'), isTrue);
          if (testCase.expectedError == ValidationErrorType.invalidReference) {
            expect(errors.any((e) => e.message.contains('@executer') && e.message.contains('@executor')), isTrue);
          }
        }
      });
    }
  });

  group('hybrid step validation rules', () {
    test('known types produce no hybrid type error', () {
      for (final type in WorkflowTaskType.values) {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: [
            WorkflowStep(
              id: 's',
              name: 'S',
              type: type,
              prompts:
                  type == WorkflowTaskType.bash ||
                      type == WorkflowTaskType.approval ||
                      type == WorkflowTaskType.aggregateReviews
                  ? null
                  : ['p'],
            ),
          ],
        );
        final report = validator.validate(def);
        expect(
          hasError(report.errors, type: ValidationErrorType.hybridStepConstraint),
          isFalse,
          reason: 'Known type "${type.toJson()}" should not produce a hybrid type error',
        );
      }
    });

    test('approval step in a loop produces a warning, not an error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'loop-step', name: 'Loop', prompts: ['p']),
          WorkflowStep(id: 'gate', name: 'Gate', type: WorkflowTaskType.approval),
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
          WorkflowStep(id: 'gate', name: 'Gate', type: WorkflowTaskType.approval),
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

    final hybridCases = [
      (
        name: 'approval step with parallel:true is a hard error',
        steps: const [WorkflowStep(id: 'gate', name: 'Gate', type: WorkflowTaskType.approval, parallel: true)],
        stepId: 'gate',
        continuityProviders: null,
        expectedError: ValidationErrorType.hybridStepConstraint,
      ),
      (
        name: 'bash step with multi-prompt list is a hard error',
        steps: const [
          WorkflowStep(id: 'build', name: 'Build', type: WorkflowTaskType.bash, prompts: ['dart analyze', 'dart test']),
        ],
        stepId: 'build',
        continuityProviders: null,
        expectedError: ValidationErrorType.hybridStepConstraint,
      ),
      (
        name: 'approval step with multi-prompt list is a hard error',
        steps: const [
          WorkflowStep(
            id: 'gate',
            name: 'Gate',
            type: WorkflowTaskType.approval,
            prompts: ['Approve?', 'Still approve?'],
          ),
        ],
        stepId: 'gate',
        continuityProviders: null,
        expectedError: ValidationErrorType.hybridStepConstraint,
      ),
      (
        name: 'approval step without parallel:true produces no error',
        steps: const [WorkflowStep(id: 'gate', name: 'Gate', type: WorkflowTaskType.approval)],
        stepId: 'gate',
        continuityProviders: null,
        expectedError: null,
      ),
      (
        name: 'bash step produces no hybrid constraint errors',
        steps: const [WorkflowStep(id: 's', name: 'Build', type: WorkflowTaskType.bash, workdir: '/workspace')],
        stepId: 's',
        continuityProviders: null,
        expectedError: null,
      ),
      (
        name: 'continueSession on first step is a hard error',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p'], continueSession: '@previous'),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p']),
        ],
        stepId: 's1',
        continuityProviders: null,
        expectedError: ValidationErrorType.hybridStepConstraint,
      ),
      (
        name: 'continueSession on non-first step with no continuityProviders produces no error',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous'),
        ],
        stepId: 's2',
        continuityProviders: null,
        expectedError: null,
      ),
      (
        name: 'continueSession with unsupported provider is a hard error',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous', provider: 'codex'),
        ],
        stepId: 's2',
        continuityProviders: {'claude'},
        expectedError: ValidationErrorType.unsupportedProviderCapability,
      ),
      (
        name: 'continueSession with supported provider produces no error',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p'], provider: 'claude'),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous', provider: 'claude'),
        ],
        stepId: 's2',
        continuityProviders: {'claude'},
        expectedError: null,
      ),
    ];

    for (final testCase in hybridCases) {
      test(testCase.name, () {
        final def = WorkflowDefinition(name: 'wf', description: 'd', steps: testCase.steps);
        final report = testCase.continuityProviders == null
            ? validator.validate(def)
            : validator.validate(def, continuityProviders: testCase.continuityProviders);
        final errorType = testCase.expectedError;

        if (errorType == null) {
          expect(hasError(report.errors, stepId: testCase.stepId), isFalse);
        } else {
          expect(hasError(report.errors, type: errorType, stepId: testCase.stepId), isTrue);
        }
      });
    }

    test('continueSession provider matches previous step provider', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], provider: 'codex'),
          WorkflowStep(
            id: 'quick-review',
            name: 'Quick Review',
            prompts: ['p'],
            continueSession: '@previous',
            provider: 'codex',
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'requires the same provider'), isFalse);
    });

    test('continueSession provider mismatch fails and names both providers', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], provider: 'codex'),
          WorkflowStep(
            id: 'quick-review',
            name: 'Quick Review',
            prompts: ['p'],
            continueSession: '@previous',
            provider: 'claude',
          ),
        ],
      );
      final report = validator.validate(def);
      final error = report.errors.singleWhere((e) => e.message.contains('requires the same provider'));
      expect(error.message, contains('implement'));
      expect(error.message, contains('quick-review'));
      expect(error.message, contains('codex'));
      expect(error.message, contains('claude'));
    });

    test('continueSession provider comparison resolves role aliases', () {
      final validator = WorkflowDefinitionValidator(
        roleDefaults: const WorkflowRoleDefaults(
          workflow: WorkflowRoleDefault(provider: 'claude'),
          executor: WorkflowRoleDefault(provider: 'codex'),
        ),
      );
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], provider: 'codex'),
          WorkflowStep(
            id: 'quick-review',
            name: 'Quick Review',
            prompts: ['p'],
            continueSession: '@previous',
            provider: '@executor',
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'requires the same provider'), isFalse);
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
      expect(hasError(report.errors, type: ValidationErrorType.unsupportedProviderCapability, stepId: 's2'), isFalse);
    });

    test('continueSession with unknown @-prefixed provider produces invalidReference error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], continueSession: '@previous', provider: '@executer'),
        ],
      );
      final report = validator.validate(def, continuityProviders: {'claude'});
      expect(
        report.errors.any(
          (e) =>
              e.type == ValidationErrorType.invalidReference &&
              e.stepId == 's2' &&
              e.message.contains('@executer') &&
              e.message.contains('@executor'),
        ),
        isTrue,
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
      expect(hasError(report.errors, type: ValidationErrorType.hybridStepConstraint, stepId: 's2'), isTrue);
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
      final def = buildDef();
      final report = validator.validate(def);
      expect(report.isEmpty, isTrue);
      expect(report.hasErrors, isFalse);
      expect(report.hasWarnings, isFalse);
    });

    test('ValidationReport.hasErrors is true when errors exist', () {
      final def = buildDef(name: ''); // missing name
      final report = validator.validate(def);
      expect(report.hasErrors, isTrue);
      expect(report.isEmpty, isFalse);
    });

    test('ValidationReport.hasWarnings is true when only warnings exist', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [WorkflowStep(id: 's', name: 'S', type: WorkflowTaskType.approval)],
        loops: [
          WorkflowLoop(id: 'loop', steps: ['s'], maxIterations: 1, exitGate: 's.done == true'),
        ],
      );
      final report = validator.validate(def);
      expect(report.hasErrors, isFalse);
      expect(report.hasWarnings, isTrue);
      expect(report.isEmpty, isFalse);
    });

    group('continueSession illegal-target validation', () {
      final cases = [
        (
          name: 'continueSession on bash step is a hard error',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
            WorkflowStep(id: 's2', name: 'S2', type: WorkflowTaskType.bash, prompts: ['echo hi']),
            WorkflowStep(id: 's3', name: 'S3', prompts: ['p'], continueSession: '@previous'),
          ],
          loops: const <WorkflowLoop>[],
          stepId: 's3',
          messageContains: 'bash',
          hasHybridError: true,
        ),
        (
          name: 'continueSession on approval step is a hard error',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
            WorkflowStep(id: 's2', name: 'S2', type: WorkflowTaskType.approval, prompts: ['Approve?']),
            WorkflowStep(id: 's3', name: 'S3', prompts: ['p'], continueSession: '@previous'),
          ],
          loops: const <WorkflowLoop>[],
          stepId: 's3',
          messageContains: 'approval',
          hasHybridError: true,
        ),
        (
          name: 'continueSession step that itself is bash is a hard error',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
            WorkflowStep(
              id: 's2',
              name: 'S2',
              type: WorkflowTaskType.bash,
              prompts: ['echo hi'],
              continueSession: '@previous',
            ),
          ],
          loops: const <WorkflowLoop>[],
          stepId: 's2',
          messageContains: null,
          hasHybridError: true,
        ),
        (
          name: 'continueSession crossing a loop boundary is a hard error',
          steps: const [
            WorkflowStep(id: 'inside', name: 'Inside', prompts: ['p']),
            WorkflowStep(id: 'outside', name: 'Outside', prompts: ['p'], continueSession: 'inside'),
          ],
          loops: const [
            WorkflowLoop(id: 'loop1', steps: ['inside'], exitGate: '{{context.done}}', maxIterations: 3),
          ],
          stepId: 'outside',
          messageContains: 'loop boundary',
          hasHybridError: true,
        ),
        (
          name: 'continueSession crossing into a loop is a hard error',
          steps: const [
            WorkflowStep(id: 'outside', name: 'Outside', prompts: ['p']),
            WorkflowStep(id: 'inside', name: 'Inside', prompts: ['p'], continueSession: 'outside'),
          ],
          loops: const [
            WorkflowLoop(id: 'loop1', steps: ['inside'], exitGate: '{{context.done}}', maxIterations: 3),
          ],
          stepId: 'inside',
          messageContains: 'loop boundary',
          hasHybridError: true,
        ),
        (
          name: 'continueSession within the same loop is valid',
          steps: const [
            WorkflowStep(id: 'step1', name: 'Step1', prompts: ['p']),
            WorkflowStep(id: 'step2', name: 'Step2', prompts: ['p'], continueSession: 'step1'),
          ],
          loops: const [
            WorkflowLoop(id: 'loop1', steps: ['step1', 'step2'], exitGate: '{{context.done}}', maxIterations: 3),
          ],
          stepId: 'step2',
          messageContains: null,
          hasHybridError: false,
        ),
        (
          name: 'valid linear continueSession chain produces no error',
          steps: const [
            WorkflowStep(id: 's1', name: 'S1', prompts: ['Investigate']),
            WorkflowStep(id: 's2', name: 'S2', prompts: ['Fix it'], continueSession: 's1'),
            WorkflowStep(id: 's3', name: 'S3', prompts: ['Verify'], continueSession: 's2'),
          ],
          loops: const <WorkflowLoop>[],
          stepId: null,
          messageContains: null,
          hasHybridError: false,
        ),
      ];

      for (final testCase in cases) {
        test(testCase.name, () {
          final def = WorkflowDefinition(name: 'wf', description: 'd', steps: testCase.steps, loops: testCase.loops);
          final report = validator.validate(def);
          expect(
            hasError(
              report.errors,
              type: ValidationErrorType.hybridStepConstraint,
              stepId: testCase.stepId,
              messageContains: testCase.messageContains,
            ),
            testCase.hasHybridError,
          );
        });
      }
    });
  });
}
