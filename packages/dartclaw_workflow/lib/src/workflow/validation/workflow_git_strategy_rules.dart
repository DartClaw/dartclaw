part of '../workflow_definition_validator.dart';

extension _WorkflowGitStrategyRules on WorkflowDefinitionValidator {
  void _validateGitStrategy(
    WorkflowDefinition definition,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    final strategy = definition.gitStrategy;
    if (strategy == null) return;

    const worktreeValues = {'shared', 'per-task', 'per-map-item', 'inline', 'auto'};
    const promotionValues = {'merge', 'rebase', 'none'};

    final worktree = strategy.worktreeMode;
    if (worktree != null && !worktreeValues.contains(worktree)) {
      errors.add(
        _err(
          ValidationErrorType.invalidReference,
          'gitStrategy.worktree must be one of ${worktreeValues.join(', ')}; '
          'received "$worktree".',
        ),
      );
    }

    final promotion = strategy.promotion;
    if (promotion != null && !promotionValues.contains(promotion)) {
      errors.add(
        _err(
          ValidationErrorType.invalidReference,
          'gitStrategy.promotion must be one of ${promotionValues.join(', ')}; '
          'received "$promotion".',
        ),
      );
    }

    // Artifact-producing step detection — a step is artifact-producing if any
    // output declares format: path. Shares the runtime committer's detector so
    // validation and commit-time behavior agree on what "artifact-producing"
    // means (ADR-041: generic format: path, not a key-name allowlist).
    final hasArtifactProducer = workflowHasArtifactProducer(definition);

    final artifacts = strategy.artifacts;
    // gitStrategy.artifacts.commit defaulting truth table:
    //   - ≥1 artifact-producing step → default commit=true; commit=false with
    //     worktree=per-map-item is a hard error; commit=false with shared is
    //     allowed but warned.
    //   - No artifact-producing step → default commit=false; any explicit
    //     value is accepted silently.
    if (hasArtifactProducer) {
      final commitExplicit = artifacts?.commit;
      final resolvedArtifactWorktreeMode = _resolvedWorktreeModeForValidation(definition, strategy);
      if (commitExplicit == false && resolvedArtifactWorktreeMode == 'per-map-item') {
        errors.add(
          _err(
            ValidationErrorType.invalidReference,
            'gitStrategy.artifacts.commit: false is incompatible with '
            'gitStrategy.worktree: per-map-item when the workflow contains '
            'artifact-producing steps — worktrees cannot inherit uncommitted '
            'generated artifacts. Set artifacts.commit: true or change the '
            'worktree strategy.',
          ),
        );
      } else if (commitExplicit == false && resolvedArtifactWorktreeMode == 'shared') {
        warnings.add(
          _err(
            ValidationErrorType.invalidReference,
            'gitStrategy.artifacts.commit: false with worktree: shared is '
            'allowed but uncommitted artifacts will not persist beyond the '
            'workflow branch trace; consider enabling commit.',
          ),
        );
      }
    }

    final mount = strategy.externalArtifactMount;
    if (mount != null) {
      if (mount.mode == WorkflowExternalArtifactMountMode.perStoryCopy &&
          (mount.source == null || mount.source!.trim().isEmpty)) {
        errors.add(
          _err(
            ValidationErrorType.invalidReference,
            'gitStrategy.externalArtifactMount.source is required when mode '
            'is "per-story-copy" (a template resolved per map iteration, '
            'e.g. "{{map.item.spec_path}}").',
          ),
        );
      }
      if (mount.mode == WorkflowExternalArtifactMountMode.bindMount) {
        if (mount.fromPath == null || mount.fromPath!.trim().isEmpty) {
          errors.add(
            _err(
              ValidationErrorType.invalidReference,
              'gitStrategy.externalArtifactMount.fromPath is required when '
              'mode is "bind-mount".',
            ),
          );
        }
        warnings.add(
          _err(
            ValidationErrorType.invalidReference,
            'gitStrategy.externalArtifactMount.mode: "bind-mount" broadens '
            'the sandbox scope of each per-story worktree beyond its own '
            'story spec. Ensure the profile README justifies this opt-in.',
          ),
        );
      }
    }

    // TD-073: detect a static source that would cause all parallel map
    // iterations to write the same file to the same destination path.
    if (mount != null &&
        mount.mode == WorkflowExternalArtifactMountMode.perStoryCopy &&
        mount.source != null &&
        !mount.source!.contains('{{')) {
      final resolvedMode = _resolvedWorktreeModeForValidation(definition, strategy);
      final hasParallelMap = definition.steps.any((step) {
        if (step.mapOver == null) return false;
        final mp = _staticMaxParallel(step.maxParallel);
        return mp == null || mp > 1;
      });
      if (hasParallelMap && resolvedMode == 'per-map-item') {
        errors.add(
          _err(
            ValidationErrorType.invalidReference,
            'gitStrategy.externalArtifactMount.source is a literal path '
            '"${mount.source}" with no template variables. All parallel '
            'map iterations will copy the same source to the same destination '
            'in their respective worktrees. Use a template variable such as '
            '"{{map.item.spec_path}}" to differentiate per-iteration sources.',
          ),
        );
      }
    }

    final branchDefault = definition.variables['BRANCH']?.defaultValue?.trim();
    if (strategy.integrationBranch == true && branchDefault == 'main') {
      warnings.add(
        _err(
          ValidationErrorType.invalidReference,
          'variables.BRANCH.default: "main" with gitStrategy.integrationBranch: true '
          'hardcodes workflow branch creation to main for local-path projects. '
          'Prefer leaving BRANCH empty and letting workflow start resolve '
          'the effective base ref from the project.',
        ),
      );
    }

    _validateMergeResolve(strategy, errors);
  }

  void _validateMergeResolve(WorkflowGitStrategy strategy, List<ValidationError> errors) {
    final mr = strategy.mergeResolve;

    // TI04 — BPC-14/17 row 1: enabled:true requires promotion:merge
    if (mr.enabled && strategy.promotion != 'merge') {
      errors.add(
        _err(
          ValidationErrorType.invalidReference,
          'WorkflowDefinitionError: gitStrategy.merge_resolve.enabled requires '
          'gitStrategy.promotion: merge',
        ),
      );
    }

    // TI05 — BPC-15/17 row 2: max_attempts range 1–5
    if (mr.maxAttempts < 1 || mr.maxAttempts > 5) {
      errors.add(
        _err(
          ValidationErrorType.invalidReference,
          'WorkflowDefinitionError: gitStrategy.merge_resolve.max_attempts '
          'must be between 1 and 5',
        ),
      );
    }

    // TI06 — BPC-16/17 row 3: token_ceiling range 10000–500000
    if (mr.tokenCeiling < 10000 || mr.tokenCeiling > 500000) {
      errors.add(
        _err(
          ValidationErrorType.invalidReference,
          'WorkflowDefinitionError: gitStrategy.merge_resolve.token_ceiling '
          'must be between 10000 and 500000',
        ),
      );
    }

    // TI07 — BPC-17 row 4: escalation:pause reserved; generic enum check
    final rawEsc = mr.rawEscalation;
    if (rawEsc != null) {
      if (rawEsc == 'pause') {
        errors.add(
          _err(
            ValidationErrorType.invalidReference,
            "WorkflowDefinitionError: gitStrategy.merge_resolve.escalation: 'pause' is reserved for a future release",
          ),
        );
      } else if (mr.escalation == null) {
        errors.add(
          _err(
            ValidationErrorType.invalidReference,
            'WorkflowDefinitionError: gitStrategy.merge_resolve.escalation '
            'must be one of serialize-remaining, fail',
          ),
        );
      }
    }

    // Unknown fields under merge_resolve.
    for (final name in mr.unknownFields) {
      errors.add(
        _err(
          ValidationErrorType.invalidReference,
          "WorkflowDefinitionError: unknown field '$name' under gitStrategy.merge_resolve",
        ),
      );
    }
  }

  String _resolvedWorktreeModeForValidation(WorkflowDefinition definition, WorkflowGitStrategy strategy) {
    final authored = strategy.worktreeMode?.trim();
    if (authored != null && authored.isNotEmpty && authored != 'auto') {
      return authored;
    }

    final mapLikeSteps = definition.steps.where((step) => step.mapOver != null);
    if (mapLikeSteps.isEmpty) {
      return strategy.effectiveWorktreeMode(maxParallel: 1, isMap: false);
    }

    for (final step in mapLikeSteps) {
      final maxParallel = _staticMaxParallel(step.maxParallel);
      if (maxParallel == null || maxParallel > 1) {
        return strategy.effectiveWorktreeMode(maxParallel: 2, isMap: true);
      }
    }

    return strategy.effectiveWorktreeMode(maxParallel: 1, isMap: true);
  }

  int? _staticMaxParallel(Object? value) {
    if (value == null) return 1;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return 1;
      return int.tryParse(trimmed);
    }
    return null;
  }

  void _validateStepDefaultsOrdering(WorkflowDefinition definition, List<ValidationError> warnings) {
    final defaults = definition.stepDefaults;
    if (defaults == null || defaults.length < 2) return;

    final seen = <String>{};
    for (final step in definition.steps) {
      for (var i = 0; i < defaults.length; i++) {
        final current = defaults[i];
        if (current.match == '*') continue; // intentional catch-all; too noisy to warn on
        if (current.match.contains('*') || !globMatchStepId(current.match, step.id)) continue;

        for (var j = i + 1; j < defaults.length; j++) {
          final later = defaults[j];
          if (later.match == '*') continue;
          if (!later.match.contains('*') || !globMatchStepId(later.match, step.id)) continue;

          final key = '${step.id}\x00${current.match}\x00${later.match}';
          if (!seen.add(key)) continue;
          warnings.add(
            _err(
              ValidationErrorType.invalidReference,
              'Info: stepDefaults ordering is load-bearing for step "${step.id}" — '
              'both ${current.match} and ${later.match} match. The first match wins, '
              'so reordering or glob widening can change which provider/model applies.',
              stepId: step.id,
            ),
          );
          break;
        }
      }
    }
  }
}
