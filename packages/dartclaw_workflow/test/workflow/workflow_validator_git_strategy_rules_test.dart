import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
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
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.shared),
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: true),
        ),
      );
      expect(validator.validate(def).errors, isEmpty);
    });

    test('integration branch workflows warn when BRANCH defaults to main', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        variables: const {'BRANCH': WorkflowVariable(required: false, description: 'Base ref', defaultValue: 'main')},
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        gitStrategy: const WorkflowGitStrategy(integrationBranch: true),
      );

      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single.message, contains('variables.BRANCH.default: "main"'));
      expect(report.warnings.single.message, contains('gitStrategy.integrationBranch: true'));
    });

    test('legacy bootstrap key emits migration warning', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        gitStrategy: const WorkflowGitStrategy(integrationBranch: true, legacyBootstrapKey: true),
      );

      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single.message, contains('gitStrategy.bootstrap is deprecated'));
      expect(report.warnings.single.message, contains('gitStrategy.integrationBranch'));
    });

    test('invalid gitStrategy promotion produces validation error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        gitStrategy: const WorkflowGitStrategy(promotion: 'invalid-promotion'),
      );

      final errors = validator.validate(def).errors;
      expect(errors, hasLength(1));
      expect(errors.map((e) => e.message).join('\n'), contains('gitStrategy.promotion'));
    });

    test('auto and inline worktree values are accepted', () {
      for (final worktreeMode in [WorkflowGitWorktreeMode.auto, WorkflowGitWorktreeMode.inline]) {
        final def = WorkflowDefinition(
          name: 'wf-${worktreeMode.toJson()}',
          description: 'd',
          steps: const [
            WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          ],
          gitStrategy: WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: worktreeMode)),
        );
        expect(
          validator.validate(def).errors,
          isEmpty,
          reason: 'worktree mode "${worktreeMode.toJson()}" should validate',
        );
      }
    });
  });

  group('gitStrategy.artifacts validation', () {
    test('per-map-item + artifact producer + commit: false raises error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          artifacts: WorkflowGitArtifactsStrategy(commit: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            skill: 'andthen:plan',
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'artifacts.commit: false is incompatible'), isTrue);
    });

    test('auto + map step maxParallel > 1 + artifact producer + commit: false raises error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto),
          artifacts: WorkflowGitArtifactsStrategy(commit: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            skill: 'andthen:plan',
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], mapOver: 'stories', maxParallel: 2),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'artifacts.commit: false is incompatible'), isTrue);
    });

    test('auto + map step maxParallel 1 + artifact producer + commit: false does not raise per-map-item error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto),
          artifacts: WorkflowGitArtifactsStrategy(commit: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            skill: 'andthen:plan',
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], mapOver: 'stories', maxParallel: 1),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'artifacts.commit: false is incompatible'), isFalse);
    });

    test('shared + artifact producer + commit: false issues warning not error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.shared),
          artifacts: WorkflowGitArtifactsStrategy(commit: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            skill: 'andthen:plan',
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'artifacts.commit'), isFalse);
      expect(report.warnings.any((w) => w.message.contains('worktree: shared')), isTrue);
    });

    test('no artifact producer + per-map-item accepted', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
        ),
        steps: const [
          WorkflowStep(id: 'only', name: 'Only', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'artifacts.commit'), isFalse);
    });

    test('review_report_path-only producer is detected (generic format: path, not a key-name allowlist)', () {
      // A custom workflow whose sole path output is review_report_path — not in
      // the retired key-name allowlist — must still be recognised as
      // artifact-producing so the per-map-item + commit: false guard fires.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          artifacts: WorkflowGitArtifactsStrategy(commit: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            skill: 'andthen:review',
            outputs: {'review_report_path': OutputConfig(format: OutputFormat.path)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'artifacts.commit: false is incompatible'), isTrue);
    });

    test('story_specs-only producer is detected through schema metadata', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          artifacts: WorkflowGitArtifactsStrategy(commit: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            skill: 'some:plan',
            outputs: {'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs')},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'artifacts.commit: false is incompatible'), isTrue);
    });

    test('externalArtifactMount per-story-copy without source raises error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(
            mode: WorkflowGitWorktreeMode.perMapItem,
            externalArtifactMount: WorkflowGitExternalArtifactMount(
              mode: WorkflowExternalArtifactMountMode.perStoryCopy,
              fromProject: 'DOC',
            ),
          ),
        ),
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'externalArtifactMount.source'), isTrue);
    });

    test('externalArtifactMount bind-mount without fromPath raises error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(
            mode: WorkflowGitWorktreeMode.perMapItem,
            externalArtifactMount: WorkflowGitExternalArtifactMount(
              mode: WorkflowExternalArtifactMountMode.bindMount,
              fromProject: 'DOC',
            ),
          ),
        ),
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'externalArtifactMount.fromPath'), isTrue);
    });

    test('flat-level externalArtifactMount emits migration error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(
            mode: WorkflowGitWorktreeMode.perMapItem,
            externalArtifactMount: WorkflowGitExternalArtifactMount(
              mode: WorkflowExternalArtifactMountMode.perStoryCopy,
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
      expect(hasError(report.errors, messageContains: 'gitStrategy.worktree.externalArtifactMount'), isTrue);
    });

    test('TD-073: literal source with parallel map emits collision error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(
            mode: WorkflowGitWorktreeMode.perMapItem,
            externalArtifactMount: WorkflowGitExternalArtifactMount(
              mode: WorkflowExternalArtifactMountMode.perStoryCopy,
              fromProject: 'DOC',
              source: 'dev/specs/plan.md', // literal – no {{}} – all iterations write same path
            ),
          ),
        ),
        steps: const [
          WorkflowStep(id: 'impl', name: 'Impl', prompts: ['p'], mapOver: 'stories', maxParallel: 3),
        ],
      );
      final report = validator.validate(def);
      expect(
        report.errors.any((e) => e.message.contains('literal path') && e.message.contains('plan.md')),
        isTrue,
        reason: 'validator should flag literal source with parallel map as collision risk',
      );
    });

    test('TD-073: template source with parallel map passes validation', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(
            mode: WorkflowGitWorktreeMode.perMapItem,
            externalArtifactMount: WorkflowGitExternalArtifactMount(
              mode: WorkflowExternalArtifactMountMode.perStoryCopy,
              fromProject: 'DOC',
              source: '{{map.item.spec_path}}', // template – varies per item – no collision
            ),
          ),
        ),
        steps: const [
          WorkflowStep(id: 'impl', name: 'Impl', prompts: ['p'], mapOver: 'stories', maxParallel: 3),
        ],
      );
      final report = validator.validate(def);
      expect(
        hasError(report.errors, messageContains: 'literal path'),
        isFalse,
        reason: 'template source should not trigger the collision error',
      );
    });

    test('stepDefaults ordering note is not emitted for non-overlapping literal and glob', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        stepDefaults: const [
          StepConfigDefault(match: 'revise*', provider: '@reviewer'),
          StepConfigDefault(match: 'spec', provider: '@planner'),
          StepConfigDefault(match: '*', provider: '@workflow'),
        ],
        steps: const [
          WorkflowStep(id: 'spec', name: 'Spec', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(report.warnings.any((w) => w.message.contains('stepDefaults ordering is load-bearing')), isFalse);
    });

    test('stepDefaults ordering note is emitted when literal overlaps with later glob', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        stepDefaults: const [
          StepConfigDefault(match: 'spec-foo', provider: '@planner'),
          StepConfigDefault(match: 'spec*', provider: '@reviewer'),
          StepConfigDefault(match: '*', provider: '@workflow'),
        ],
        steps: const [
          WorkflowStep(id: 'spec-foo', name: 'Spec Foo', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      final warning = report.warnings.singleWhere((w) => w.message.contains('stepDefaults ordering is load-bearing'));
      expect(warning.message, contains('spec-foo'));
      expect(warning.message, contains('spec*'));
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

    // TI04 – BPC-17 row 1
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
      expect(hasError(errors, messageContains: 'merge_resolve.enabled'), isFalse);
    });

    test('enabled:true with promotion:merge produces no row-1 error', () {
      final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: true), promotion: 'merge');
      final errors = validator.validate(def).errors;
      expect(hasError(errors, messageContains: 'merge_resolve.enabled'), isFalse);
    });

    // TI05 – BPC-17 row 2: max_attempts bounds (1..5). Out-of-range emits the exact row-2 error.
    const maxAttemptsError = 'WorkflowDefinitionError: gitStrategy.merge_resolve.max_attempts must be between 1 and 5';
    for (final (value, valid) in const [(0, false), (1, true), (5, true), (6, false)]) {
      test('max_attempts:$value ${valid ? 'is valid' : 'emits exact BPC-17 row 2 error'}', () {
        final errors = validator.validate(mrDef(mergeResolve: MergeResolveConfig(maxAttempts: value))).errors;
        if (valid) {
          expect(hasError(errors, messageContains: 'max_attempts'), isFalse);
        } else {
          expect(errors.any((e) => e.message == maxAttemptsError), isTrue);
        }
      });
    }

    // TI06 – BPC-17 row 3: token_ceiling bounds (10000..500000). Out-of-range emits the exact row-3 error.
    const tokenCeilingError =
        'WorkflowDefinitionError: gitStrategy.merge_resolve.token_ceiling must be between 10000 and 500000';
    for (final (value, valid) in const [(9999, false), (10000, true), (500000, true), (500001, false)]) {
      test('token_ceiling:$value ${valid ? 'is valid' : 'emits exact BPC-17 row 3 error'}', () {
        final errors = validator.validate(mrDef(mergeResolve: MergeResolveConfig(tokenCeiling: value))).errors;
        if (valid) {
          expect(hasError(errors, messageContains: 'token_ceiling'), isFalse);
        } else {
          expect(errors.any((e) => e.message == tokenCeilingError), isTrue);
        }
      });
    }

    // TI07 – BPC-17 row 4
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
        hasError(errors, messageContains: 'must be one of'),
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
      expect(hasError(errors, messageContains: "'pause' is reserved"), isFalse);
    });

    test('escalation:serialize-remaining is valid', () {
      final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'escalation': 'serialize-remaining'}));
      expect(hasError(validator.validate(def).errors, messageContains: 'escalation'), isFalse);
    });

    test('escalation:fail is valid', () {
      final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'escalation': 'fail'}));
      expect(hasError(validator.validate(def).errors, messageContains: 'escalation'), isFalse);
    });

    // TI08 – BPC-17 row 5
    test('unknown top-level key emits exact BPC-17 row 5 error', () {
      final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'foo': 'bar'}));
      final errors = validator.validate(def).errors;
      expect(
        errors.any((e) => e.message == "WorkflowDefinitionError: unknown field 'foo' under gitStrategy.merge_resolve"),
        isTrue,
      );
    });

    test('stale verification block emits unknown top-level key error', () {
      final def = mrDef(
        mergeResolve: MergeResolveConfig.fromJson({
          'verification': {'format': 'x'},
        }),
      );
      final errors = validator.validate(def).errors;
      expect(
        errors.any(
          (e) => e.message == "WorkflowDefinitionError: unknown field 'verification' under gitStrategy.merge_resolve",
        ),
        isTrue,
      );
    });

    test('two unknown top-level keys produce two errors', () {
      final def = mrDef(mergeResolve: MergeResolveConfig.fromJson({'foo': 1, 'bar': 2}));
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.message.contains('under gitStrategy.merge_resolve')).length, 2);
    });

    // TI09 – Backward compat: merge_resolve absent
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
      expect(hasError(errors, messageContains: 'merge_resolve'), isFalse);
    });

    test('merge_resolve:enabled:false with any promotion passes validation', () {
      for (final promo in ['squash', 'none', 'merge', null]) {
        final def = mrDef(mergeResolve: const MergeResolveConfig(enabled: false), promotion: promo);
        expect(
          hasError(validator.validate(def).errors, messageContains: 'merge_resolve'),
          isFalse,
          reason: 'promotion=$promo should not trigger merge_resolve errors when disabled',
        );
      }
    });
  });
}
