// Systematic prompt and structural contract suite for the three built-in
// workflow definitions (spec-and-implement, plan-and-implement, code-review).
//
// These tests are invariants – they assert properties that must hold for every
// future edit to the YAML definitions. Breaking one of them means either the
// contract has genuinely changed (update the test) or the definition drifted
// in a way that would only be noticed 30+ minutes into an E2E run.
//
// Contract categories:
//  * Structural: every workflow has expected shape (entry/exit steps, loop
//    bounds, skill presence, etc.)
//  * State tracking: built-in authoring workflows do not add a separate
//    `update-state` step; agents may update state docs during authored work.
//  * Tool permissions: structured review steps are read-only, file-backed
//    review steps may write their report artifact, implement/remediate may
//    write, discovery/classification steps are read-only.
//  * Prompt minimality: step prompts are compact invocation hints that name
//    the skill input and automation flags, not long instruction blocks.
//  * Variable passthrough: authored input variables (FEATURE/TARGET) leak
//    into at most the steps that need them.
//
// Tests that assert behavior the current YAML does NOT yet satisfy are marked
// with a `skip:` and an explicit open-issue reference. They fire the moment
// the YAML is tightened, preventing silent regressions.
library;

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/execution_envelope_schema.dart'
    show modelDerivedFinalizerKeys, stepNeedsFinalizer;
import 'package:dartclaw_workflow/src/workflow/review_finding_derivations.dart'
    show deriveReviewFindingCountFromVerdict;
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart' show WorkflowTemplateEngine;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_support/workflow_test_paths.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

WorkflowDefinition _load(String fileName) {
  final yaml = File(p.join(workflowDefinitionsDir(), fileName)).readAsStringSync();
  return WorkflowDefinitionParser().parse(yaml);
}

String _loadSource(String fileName) => File(p.join(workflowDefinitionsDir(), fileName)).readAsStringSync();

WorkflowDefinition _loadInline(String fileName) {
  final dir = findAncestorDir(['.dartclaw/workflows/custom']);
  final yaml = File(p.join(dir, fileName)).readAsStringSync();
  return WorkflowDefinitionParser().parse(yaml);
}

/// All authored steps in a workflow. The parser already flattens foreach/loop
/// bodies into `def.steps`; nested steps live side-by-side with top-level ones
/// and are referenced from controllers via `foreachSteps` / `WorkflowLoop.steps`.
Iterable<WorkflowStep> _flattenedSteps(WorkflowDefinition def) => def.steps;

/// Concatenates a step's prompt plus every `prompts[*]` entry. Used to match
/// against forbidden/required clauses without caring whether the step is
/// single- or multi-prompt.
String _allPromptText(WorkflowStep step) {
  final buffer = StringBuffer();
  for (final p in step.prompts ?? const <String>[]) {
    buffer.writeln(p);
  }
  return buffer.toString();
}

String? _effectiveDescription(OutputConfig? config) =>
    config == null ? null : PromptAugmenter.effectiveDescription(config);

/// Returns a review step's single review-report path output entry, or null.
///
/// Review steps declare exactly one `format: path` output backed by the
/// canonical `review_report_path` preset – the report artifact. Keyed
/// generically (not by literal name) so the lookup survives the step-prefixed
/// output-key convention (`<stepId>.review_report_path`).
MapEntry<String, OutputConfig>? _reviewReportPathOutput(WorkflowStep step) {
  final entries = (step.outputs ?? const <String, OutputConfig>{}).entries
      .where((e) => e.value.format == OutputFormat.path && e.value.presetName == 'review_report_path')
      .toList();
  return entries.length == 1 ? entries.single : null;
}

/// Returns the declared input / workflowVariable keys whose value is already
/// interpolated in [promptText], making the declaration a redundant no-op.
///
/// Mirrors `SkillPromptBuilder.appendAutoFramedContext` Detection B: a
/// referenced key is NOT auto-framed, so declaring it as an input
/// (`{{context.key}}`) or workflowVariable (`{{KEY}}`) adds nothing. The `.`→`_`
/// tag-normalized form is accepted too, matching the auto-framer's tolerance.
///
/// The auto-framer keys Detection B on `step.prompts.first`, while [promptText]
/// here is the full concatenated prompt (`_allPromptText`). The two coincide for
/// every current built-in skill step (all single-prompt); a future multi-prompt
/// skill step declaring an input referenced only in a later prompt would trip
/// this rule (a loud false positive), not silently pass — scan `prompts.first`
/// if that case ever ships.
Set<String> _redundantlyDeclaredKeys({
  required String promptText,
  required List<String> inputs,
  required List<String> variables,
}) {
  bool referenced(String key, {required bool isContextInput}) {
    final tag = key.replaceAll('.', '_');
    for (final candidate in {key, tag}) {
      final pattern = isContextInput ? 'context.$candidate' : candidate;
      if (RegExp('\\{\\{\\s*${RegExp.escape(pattern)}\\s*\\}\\}').hasMatch(promptText)) return true;
    }
    return false;
  }

  return {
    for (final key in inputs)
      if (referenced(key, isContextInput: true)) key,
    for (final key in variables)
      if (referenced(key, isContextInput: false)) key,
  };
}

const _builtInWorkflows = ['spec-and-implement.yaml', 'plan-and-implement.yaml', 'code-review.yaml'];
const _inlineWorkflows = ['spec-and-implement-inline.yaml', 'plan-and-implement-inline.yaml'];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Built-in workflow structural invariants', () {
    test('all three built-in definitions parse cleanly', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        expect(def.name, isNotEmpty, reason: '$file must declare a name');
        expect(def.steps, isNotEmpty, reason: '$file must declare at least one step');
      }
    });

    test('every agent step declares a skill', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (step.taskType != WorkflowTaskType.agent) continue;
          expect(step.skill, isNotNull, reason: '$file → step "${step.id}" is type=agent but has no skill:');
          expect(step.skill, isNotEmpty, reason: '$file → step "${step.id}" skill is empty');
        }
      }
    });

    test('every loop declares a bounded maxIterations', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final loop in def.loops) {
          expect(
            loop.maxIterations,
            greaterThan(0),
            reason: '$file → loop "${loop.id}" must declare a positive maxIterations',
          );
          expect(
            loop.maxIterations,
            lessThanOrEqualTo(10),
            reason: '$file → loop "${loop.id}" maxIterations should stay bounded; tighten if larger',
          );
        }
      }
    });

    test('built-in workflows do not include a separate update-state step', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        expect(
          _flattenedSteps(def).map((s) => s.id),
          isNot(contains('update-state')),
          reason:
              '$file should let authoring/remediation steps update state docs as needed instead of dispatching a final update-state task',
        );
      }
    });

    test('plan-and-implement starts with discover-plan-state', () {
      final def = _load('plan-and-implement.yaml');
      expect(
        def.steps.first.id,
        'discover-plan-state',
        reason: 'plan-and-implement must fail fast on missing PRD and expose story_specs for foreach',
      );
      expect(def.steps.first.skill, 'dartclaw-discover-andthen-plan');

      final plan = def.steps.singleWhere((step) => step.id == 'plan');
      expect(plan.entryGate, isNot(contains('story_specs.items isEmpty')));
      expect(plan.entryGate, "plan == null || plan == '' || story_specs == null || story_specs.items == null");

      final inline = _loadInline('plan-and-implement-inline.yaml');
      final inlinePlan = inline.steps.singleWhere((step) => step.id == 'plan');
      expect(inlinePlan.entryGate, isNot(contains('story_specs.items isEmpty')));
      expect(inlinePlan.entryGate, plan.entryGate);
    });

    test('spec-and-implement and code-review do not include project discovery steps', () {
      for (final file in const ['spec-and-implement.yaml', 'code-review.yaml']) {
        final def = _load(file);
        expect(
          _flattenedSteps(def).map((s) => s.id),
          isNot(contains('discover-project')),
          reason: '$file should let downstream skills navigate the project directly',
        );
      }
    });

    test('spec-and-implement and code-review begin with their respective guard/work step', () {
      expect(_load('spec-and-implement.yaml').steps.first.id, 'detect-spec-input');
      expect(_load('code-review.yaml').steps.first.id, 'review-code');
    });

    test('plan-and-implement runs implement → simplify-code → review → nested loop per story', () {
      final def = _load('plan-and-implement.yaml');
      expect(_flattenedSteps(def).where((step) => step.id == 'refactor'), isEmpty);
      // quick-review is gone; the per-story converging loop replaces it.
      expect(_flattenedSteps(def).where((step) => step.skill == 'andthen:quick-review'), isEmpty);
      expect(_flattenedSteps(def).where((step) => step.skill == 'andthen:simplify-code'), hasLength(1));

      final storyPipeline = def.nodes.whereType<ForeachNode>().singleWhere((node) => node.stepId == 'story-pipeline');
      final stepIds = storyPipeline.childStepIds;
      expect(stepIds.indexOf('simplify-code'), stepIds.indexOf('implement') + 1);
      expect(stepIds.indexOf('review-story'), stepIds.indexOf('simplify-code') + 1);
      expect(stepIds.indexOf('story-remediation'), stepIds.indexOf('review-story') + 1);

      final simplify = _flattenedSteps(def).singleWhere((step) => step.id == 'simplify-code');
      expect(simplify.skill, 'andthen:simplify-code');
      expect(simplify.provider, '@executor');
      expect(simplify.model, '@executor');
      expect(simplify.continueSession, '@previous');
      expect(simplify.onFailure, OnFailurePolicy.continueWorkflow);
      expect(simplify.maxRetries, isNull);
      // continueSession carries the implement history, so no story_result input.
      expect(simplify.inputs, isEmpty);
      expect(_allPromptText(simplify), contains('changes for this story'));

      // The per-story loop is a foreach-owned loop with the converging shape.
      final loop = def.loops.singleWhere((l) => l.id == 'story-remediation');
      expect(loop.steps, ['remediate-story', 're-review-story']);
      expect(loop.onMaxIterations, WorkflowLoop.onMaxIterationsEscalate);
      expect(loop.exitGate, 'gating_findings_count == 0');
      final review = _flattenedSteps(def).singleWhere((step) => step.id == 'review-story');
      expect(_allPromptText(review), contains('--mode gap,code,security'));
      // The loop controller declares no outputs (no review-key leak to plan level).
      final loopController = _flattenedSteps(def).singleWhere((step) => step.id == 'story-remediation');
      expect(loopController.outputKeys, isEmpty);
    });

    test('spec-and-implement simplifies once between implement and reviews', () {
      final def = _load('spec-and-implement.yaml');
      expect(_flattenedSteps(def).where((step) => step.id == 'refactor'), isEmpty);

      final stepIds = def.steps.map((step) => step.id).toList();
      expect(stepIds.indexOf('simplify-code'), stepIds.indexOf('implement') + 1);
      expect(stepIds.indexOf('integrated-review'), greaterThan(stepIds.indexOf('simplify-code')));

      final implement = def.steps.singleWhere((step) => step.id == 'implement');
      expect(implement.maxRetries, 1);

      final simplify = def.steps.singleWhere((step) => step.id == 'simplify-code');
      expect(simplify.skill, 'andthen:simplify-code');
      // provider/model are not pinned inline – they resolve to @executor via the
      // `simplify-code` stepDefault (redundant inline pins removed).
      expect(simplify.provider, isNull);
      expect(simplify.model, isNull);
      final resolvedSimplify = const WorkflowDefinitionResolver()
          .resolve(def)
          .steps
          .singleWhere((step) => step.id == 'simplify-code');
      expect(resolvedSimplify.provider, '@executor');
      expect(resolvedSimplify.model, '@executor');
      expect(simplify.onFailure, OnFailurePolicy.continueWorkflow);
      expect(simplify.maxRetries, isNull);
      expect(simplify.inputs, isEmpty);
      expect(_allPromptText(simplify), contains('current branch'));
    });

    test('inline spec simplify-code scopes by FIS, not by base ref', () {
      final def = _loadInline('spec-and-implement-inline.yaml');
      final simplify = def.steps.singleWhere((step) => step.id == 'simplify-code');
      final prompt = _allPromptText(simplify);

      // provider/model resolve to @executor via the `simplify-code` stepDefault.
      expect(simplify.provider, isNull);
      expect(simplify.model, isNull);
      final resolvedSimplify = const WorkflowDefinitionResolver()
          .resolve(def)
          .steps
          .singleWhere((step) => step.id == 'simplify-code');
      expect(resolvedSimplify.provider, '@executor');
      expect(resolvedSimplify.model, '@executor');
      expect(simplify.onFailure, OnFailurePolicy.continueWorkflow);
      expect(simplify.maxRetries, isNull);
      // spec_path is interpolated inline in the prompt – no redundant input.
      expect(simplify.inputs, isEmpty);
      expect(prompt, contains('{{context.spec_path}}'));
      expect(prompt, contains('live checkout'));
      expect(prompt, isNot(contains('base ref')));
      expect(prompt, isNot(contains('current branch')));
    });

    test('inline plan-and-implement mirrors the per-story simplify-code + nested-loop shape', () {
      final def = _loadInline('plan-and-implement-inline.yaml');
      expect(_flattenedSteps(def).where((step) => step.id == 'refactor'), isEmpty);
      expect(_flattenedSteps(def).where((step) => step.skill == 'andthen:quick-review'), isEmpty);
      expect(_flattenedSteps(def).where((step) => step.skill == 'andthen:simplify-code'), hasLength(1));

      final storyPipeline = def.nodes.whereType<ForeachNode>().singleWhere((node) => node.stepId == 'story-pipeline');
      final stepIds = storyPipeline.childStepIds;
      expect(stepIds.indexOf('simplify-code'), stepIds.indexOf('implement') + 1);
      expect(stepIds.indexOf('review-story'), stepIds.indexOf('simplify-code') + 1);
      expect(stepIds.indexOf('story-remediation'), stepIds.indexOf('review-story') + 1);

      final simplify = _flattenedSteps(def).singleWhere((step) => step.id == 'simplify-code');
      expect(simplify.skill, 'andthen:simplify-code');
      expect(simplify.provider, '@executor');
      expect(simplify.model, '@executor');
      expect(simplify.continueSession, '@previous');
      expect(simplify.onFailure, OnFailurePolicy.continueWorkflow);
      expect(simplify.maxRetries, isNull);
      // continueSession carries the implement history, so no story_result input.
      expect(simplify.inputs, isEmpty);
      expect(_allPromptText(simplify), contains('changes for this story'));

      final loop = def.loops.singleWhere((l) => l.id == 'story-remediation');
      expect(loop.steps, ['remediate-story', 're-review-story']);
      expect(loop.exitGate, 'gating_findings_count == 0');
      final loopController = _flattenedSteps(def).singleWhere((step) => step.id == 'story-remediation');
      expect(loopController.outputKeys, isEmpty);
    });

    test('inline workflows run the full deterministic verification gate', () {
      for (final file in const [
        'spec-and-implement-inline.yaml',
        'plan-and-implement-inline.yaml',
        'review-and-remediate-inline.yaml',
      ]) {
        final def = _loadInline(file);
        expect(
          _flattenedSteps(
            def,
          ).where((step) => const {'verify-format', 'verify-analyze', 'verify-tests'}.contains(step.id)),
          isEmpty,
          reason: '$file should not keep the old split verification gates',
        );
        final verifyAll = def.steps.singleWhere((step) => step.id == 'verify-all');
        expect(_allPromptText(verifyAll), contains('verify-gate.sh all'), reason: '$file initial gate');

        final loop = def.loops.singleWhere((candidate) => candidate.id == 'verify-fix-loop');
        expect(loop.entryGate, 'verify-all.result == fail', reason: '$file fix-loop entry gate');
        final loopNode = def.nodes.whereType<LoopNode>().singleWhere((node) => node.loopId == 'verify-fix-loop');
        expect(loopNode.stepIds, contains('verify-recheck'), reason: '$file fix-loop recheck step');

        final recheck = _flattenedSteps(def).singleWhere((step) => step.id == 'verify-recheck');
        expect(_allPromptText(recheck), contains('verify-gate.sh all'), reason: '$file recheck gate');
      }
    });

    test('inline remediation-loop opts into onMaxIterations: continue; verify-fix-loop stays fail (TI05)', () {
      for (final file in const [
        'spec-and-implement-inline.yaml',
        'plan-and-implement-inline.yaml',
        'review-and-remediate-inline.yaml',
      ]) {
        final def = _loadInline(file);
        final remediation = def.loops.singleWhere((loop) => loop.id == 'remediation-loop');
        expect(
          remediation.onMaxIterations,
          'continue',
          reason: '$file remediation-loop must fall through to the verify gate on exhaustion',
        );
        final verifyFix = def.loops.singleWhere((loop) => loop.id == 'verify-fix-loop');
        expect(
          verifyFix.onMaxIterations,
          'fail',
          reason: '$file verify-fix-loop is the genuine gate and must keep fail-on-exhaustion',
        );
      }
    });

    test('inline verification all gate does not require a clean working tree', () {
      final dir = findAncestorDir(['.dartclaw/workflows/custom']);
      final script = File(p.join(dir, 'scripts/verify-gate.sh')).readAsStringSync();
      final allCase = RegExp(r'all\)\n([\s\S]*?)\n    ;;').firstMatch(script)!.group(1)!;

      expect(allCase, contains('run_gate whitespace'));
      expect(allCase, isNot(contains('run_gate status')));
      expect(script, contains('gate_status()'), reason: 'status remains available as an explicit operator gate');
    });
  });

  group('Tool permissions – review steps match their output contract', () {
    // Structured review steps declare an explicit allowlist with `file_write`
    // absent so step_config_policy.stepIsReadOnly returns true. File-backed
    // review steps need `file_write`; they emit a path to a report artifact
    // that the workflow validates against the task worktree. No built-in review
    // step is currently exempt from this contract.
    const writeableReviewSteps = <String>{};

    test('review steps declare tool access consistent with artifact outputs', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (!step.id.contains('review')) continue;
          if (step.taskType == WorkflowTaskType.aggregateReviews) continue;
          if (writeableReviewSteps.contains(step.id)) continue;
          expect(step.allowedTools, isNotNull, reason: '$file → review step "${step.id}" must declare allowedTools');
          final emitsPathArtifact = step.outputs?.values.any((config) => config.format == OutputFormat.path) ?? false;
          if (emitsPathArtifact) {
            expect(
              step.allowedTools,
              contains('file_write'),
              reason: '$file → file-backed review step "${step.id}" must be able to write its report artifact',
            );
          } else {
            expect(
              step.allowedTools,
              isNot(contains('file_write')),
              reason: '$file → structured review step "${step.id}" must stay read-only',
            );
          }
        }
      }
    });

    test('implement / remediate steps may write (file_write allowed when declared)', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (step.id != 'implement' && step.id != 'remediate') continue;
          if (step.allowedTools == null) continue; // default tool policy inherits from skill
          expect(
            step.allowedTools,
            contains('file_write'),
            reason: '$file → "${step.id}" declares allowedTools but omits file_write',
          );
        }
      }
    });

    // Regression guard for the standalone edit-grant bug: under one-shot
    // dontAsk the Claude allow-list grants Edit/NotebookEdit only when
    // a step's allowedTools includes file_edit. A mutation step that lists
    // file_write but not file_edit can create files yet silently fails to edit
    // existing ones. So every project-mutating step that grants file_write must
    // also grant file_edit. A step mutates the project when it runs a known
    // mutator skill (exec-spec/remediate-findings/triage) or invokes a review
    // with --fix. Re-review steps are read-only re-runs of the original review
    // (no --fix), so they are NOT mutating and hold review-only grants.
    test('mutation steps that grant file_write also grant file_edit', () {
      const mutatorSkills = {'andthen:exec-spec', 'andthen:remediate-findings', 'andthen:triage'};
      var checked = 0;
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          final tools = step.allowedTools;
          if (tools == null || !tools.contains('file_write')) continue;
          final mutates =
              mutatorSkills.contains(step.skill) ||
              (step.skill == 'andthen:review' && _allPromptText(step).contains('--fix'));
          if (!mutates) continue;
          checked++;
          expect(
            tools,
            contains('file_edit'),
            reason:
                '$file → mutation step "${step.id}" grants file_write but omits file_edit; '
                'existing-file edits would be hard-denied under one-shot dontAsk',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include file_edit-granting mutation steps');
    });

    test('re-review steps hold review-only grants (no file_edit)', () {
      // A re-review re-runs the original review (no --fix), so it must not carry
      // the file_edit mutation grant. revise-spec (a --fix review) keeps it.
      var checked = 0;
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (!step.id.startsWith('re-review')) continue;
          checked++;
          expect(
            step.allowedTools ?? const <String>[],
            isNot(contains('file_edit')),
            reason: '$file → re-review step "${step.id}" must not grant file_edit',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include re-review steps');
    });

    test('transient-failure retries are consistent on --fix and implement steps', () {
      // revise-spec (--fix over the spec) and the inline custom implement each
      // carry maxRetries: 1 for transient harness failures, matching the
      // built-in implement.
      final reviseSpec = _load('spec-and-implement.yaml').steps.singleWhere((s) => s.id == 'revise-spec');
      expect(reviseSpec.maxRetries, 1, reason: 'revise-spec must retry transient harness failures');

      final customImplement = _loadInline(
        'spec-and-implement-inline.yaml',
      ).steps.singleWhere((s) => s.id == 'implement');
      expect(customImplement.maxRetries, 1, reason: 'custom implement must retry transient harness failures');
    });

    test('discovery/classification steps are read-only', () {
      final plan = _load('plan-and-implement.yaml');
      final discover = plan.steps.firstWhere((s) => s.id == 'discover-plan-state');
      expect(discover.allowedTools, isNotNull);
      expect(
        discover.allowedTools,
        isNot(contains('file_write')),
        reason: 'plan-and-implement → discover-plan-state must never include file_write',
      );

      final spec = _load('spec-and-implement.yaml');
      final detect = spec.steps.firstWhere((s) => s.id == 'detect-spec-input');
      expect(detect.allowedTools, isNotNull);
      expect(
        detect.allowedTools,
        isNot(contains('file_write')),
        reason: 'spec-and-implement → detect-spec-input must never include file_write',
      );
    });

    test('remediation steps pass at least one report path source in the prompt', () {
      // The report path is interpolated inline ({{context.review_report_path}}),
      // which the remediate skill executes as its argument. Because it is
      // template-referenced, declaring it as an input would be a redundant no-op
      // (the no-op-inputs rule forbids it) – so this only asserts the prompt
      // reference, not an inputs declaration.
      final reportKeys = {'review_report_path', 'architecture_review_findings'};
      final referencePattern = RegExp(r'\{\{\s*context\.([A-Za-z0-9_.-]+)\s*\}\}');
      var checked = 0;

      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (step.skill != 'andthen:remediate-findings') continue;
          checked++;
          final references = referencePattern
              .allMatches(_allPromptText(step))
              .map((match) => match.group(1)!)
              .where(reportKeys.contains)
              .toList();
          expect(
            references,
            isNotEmpty,
            reason: '$file → "${step.id}" must pass at least one report path to andthen:remediate-findings',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include remediation steps');
    });

    test('remediation steps fail loudly instead of retrying mutating work', () {
      final files = <({String file, WorkflowDefinition definition})>[
        for (final file in _builtInWorkflows) (file: file, definition: _load(file)),
        for (final file in const [
          'spec-and-implement-inline.yaml',
          'plan-and-implement-inline.yaml',
          'review-and-remediate-inline.yaml',
        ])
          (file: file, definition: _loadInline(file)),
      ];
      var checked = 0;

      for (final entry in files) {
        for (final step in _flattenedSteps(entry.definition)) {
          if (step.skill != 'andthen:remediate-findings') continue;
          checked++;
          expect(step.onFailure, OnFailurePolicy.fail, reason: '${entry.file} → "${step.id}" retry policy');
          expect(step.maxRetries, isNull, reason: '${entry.file} → "${step.id}" retry budget');
        }
      }

      expect(checked, greaterThan(0), reason: 'workflows must include remediation steps');
    });

    test('andthen:review report outputs direct writes into the host-owned step artifacts dir', () {
      var checked = 0;
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (step.skill != 'andthen:review') continue;
          final reportOutput = _reviewReportPathOutput(step);
          if (reportOutput == null) continue;
          checked++;
          expect(
            _allPromptText(step),
            contains('--output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"'),
            reason: '$file → "${step.id}" must write review reports into the host-owned step artifacts dir',
          );
          final description = _effectiveDescription(reportOutput.value) ?? '';
          expect(
            description,
            contains('--output-dir'),
            reason: '$file → "${step.id}" description must keep --output-dir guidance for andthen:review callers',
          );
          expect(
            description,
            matches(RegExp(r'absolute.{0,80}--output-dir', dotAll: true)),
            reason:
                '$file → "${step.id}" description must pair the absolute-path form with --output-dir so andthen:review AUTO_MODE callers get the right contract',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include file-backed andthen:review steps');
    });

    test('parallel review source steps prefix every output key with the step id', () {
      // Convention: a review step that feeds an aggregate-reviews step prefixes
      // ALL its output keys with its step id (`<stepId>.review_report_path`,
      // `<stepId>.findings_count`, `<stepId>.gating_findings_count`). The host
      // accepts the skill's bare-suffix emission via the filesystem-claim alias,
      // so prefixing is always collision-safe. Locks out the historical
      // three-strategy split (bare `review_report_path`, distinct
      // `architecture_review_findings`, prefixed council key).
      final definitions = <String, WorkflowDefinition>{
        for (final file in _builtInWorkflows) file: _load(file),
        for (final file in const [
          'spec-and-implement-inline.yaml',
          'plan-and-implement-inline.yaml',
          'review-and-remediate-inline.yaml',
        ])
          file: _loadInline(file),
      };
      var checked = 0;

      for (final entry in definitions.entries) {
        final aggregate = _flattenedSteps(
          entry.value,
        ).where((s) => s.taskType == WorkflowTaskType.aggregateReviews).firstOrNull;
        if (aggregate == null) continue;
        final stepsById = {for (final s in _flattenedSteps(entry.value)) s.id: s};

        for (final sourceId in aggregate.aggregateReviews ?? const <String>[]) {
          final source = stepsById[sourceId]!;
          checked++;
          final prefix = '$sourceId.';
          for (final key in source.outputs?.keys ?? const <String>[]) {
            expect(
              key,
              startsWith(prefix),
              reason: '${entry.key} → source "$sourceId" output key "$key" must be prefixed with its step id',
            );
          }
          final reportOutput = _reviewReportPathOutput(source);
          expect(reportOutput?.key, '$sourceId.review_report_path', reason: '${entry.key} → "$sourceId" report key');
          expect(
            source.outputs?.containsKey('review_report_path'),
            isNot(isTrue),
            reason: '${entry.key} → "$sourceId" must not declare a bare review_report_path',
          );
          expect(
            source.outputs?.containsKey('architecture_review_findings'),
            isNot(isTrue),
            reason: '${entry.key} → "$sourceId" must not declare the legacy architecture_review_findings',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'workflows must include aggregated review source steps');
    });

    test('parallel review workflows aggregate first-pass findings and re-review overwrites simple names', () {
      final expectedSources = {
        'spec-and-implement.yaml': ['integrated-review', 'integrated-review-council', 'architecture-review'],
        'plan-and-implement.yaml': ['plan-review', 'plan-review-council', 'architecture-review'],
        'spec-and-implement-inline.yaml': ['integrated-review', 'integrated-review-council', 'architecture-review'],
        'plan-and-implement-inline.yaml': ['plan-review', 'plan-review-council', 'architecture-review'],
      };

      for (final entry in expectedSources.entries) {
        final file = entry.key;
        final def = file.endsWith('-inline.yaml') ? _loadInline(file) : _load(file);
        final aggregate = _flattenedSteps(def).firstWhere((s) => s.id == 'review-aggregate');
        final loop = def.loops.firstWhere((l) => l.id == 'remediation-loop');
        final remediate = _flattenedSteps(def).firstWhere((s) => s.id == 'remediate');
        final reReview = _flattenedSteps(def).firstWhere((s) => s.id == 're-review');

        expect(aggregate.taskType, WorkflowTaskType.aggregateReviews, reason: '$file → review-aggregate type');
        expect(aggregate.aggregateReviews, entry.value, reason: '$file → aggregate source order');
        expect(aggregate.outputKeys.toSet(), {'review_report_path', 'findings_count', 'gating_findings_count'});
        expect(loop.entryGate, 'gating_findings_count > 0', reason: '$file → loop entry gate');
        expect(loop.exitGate, 'gating_findings_count == 0', reason: '$file → loop exit gate');
        expect(remediate.entryGate, 'gating_findings_count > 0', reason: '$file → remediate entry gate');
        // review_report_path is interpolated inline in the prompt, so declaring it
        // as an input would be a redundant no-op (no-op-inputs rule).
        expect(remediate.inputs, isNot(contains('review_report_path')), reason: '$file → remediate no-op report input');
        expect(remediate.inputs, isNot(contains('architecture_review_findings')), reason: file);
        expect(_allPromptText(remediate).trim(), '--auto {{context.review_report_path}}', reason: file);
        expect(
          remediate.outputs?.containsKey('architecture-review.gating_findings_count'),
          isNot(isTrue),
          reason: file,
        );
        expect(remediate.outputs?.containsKey('architecture_review_findings'), isNot(isTrue), reason: file);
        expect(remediate.outputs?.containsKey('diff_summary'), isNot(isTrue), reason: file);
        expect(reReview.outputKeys, containsAll(['review_report_path', 'findings_count', 'gating_findings_count']));
        expect(reReview.outputKeys, isNot(contains('re-review.findings_count')), reason: file);
        expect(reReview.outputKeys, isNot(contains('re-review.gating_findings_count')), reason: file);
      }
    });

    test('remediation loop gates use gating findings, not total findings', () {
      final definitions = <String, WorkflowDefinition>{
        for (final file in _builtInWorkflows) file: _load(file),
        for (final file in const [
          'spec-and-implement-inline.yaml',
          'plan-and-implement-inline.yaml',
          'review-and-remediate-inline.yaml',
        ])
          file: _loadInline(file),
      };

      for (final entry in definitions.entries) {
        final loop = entry.value.loops.singleWhere((candidate) => candidate.id == 'remediation-loop');
        expect(loop.entryGate, contains('gating_findings_count'), reason: '${entry.key} loop entry gate');
        expect(loop.entryGate, isNot(matches(RegExp(r'(^|[^A-Za-z0-9_.-])findings_count\s*>'))));
        expect(loop.exitGate, contains('gating_findings_count'), reason: '${entry.key} loop exit gate');
        final remediate = _flattenedSteps(entry.value).singleWhere((step) => step.id == 'remediate');
        expect(
          remediate.entryGate,
          anyOf(isNull, contains('gating_findings_count')),
          reason: '${entry.key} remediate gate',
        );
      }
    });

    test('built-in review count contract uses default high severity threshold', () {
      final reviewCountKeys = <String>{};
      for (final file in _builtInWorkflows) {
        for (final step in _flattenedSteps(_load(file))) {
          reviewCountKeys.addAll(
            (step.outputs ?? const <String, OutputConfig>{}).entries
                .where((entry) => entry.value.presetName == 'gating_findings_count')
                .map((entry) => entry.key),
          );
        }
      }

      const verdict = {
        'findings_count': 4,
        'findings': [
          {'severity': 'critical', 'location': 'a.dart:1', 'description': 'critical'},
          {'severity': 'high', 'location': 'a.dart:2', 'description': 'high'},
          {'severity': 'medium', 'location': 'a.dart:3', 'description': 'medium'},
          {'severity': 'low', 'location': 'a.dart:4', 'description': 'low'},
        ],
      };

      expect(reviewCountKeys, isNotEmpty, reason: 'built-in review steps must declare gating finding counts');
      for (final key in reviewCountKeys) {
        expect(
          deriveReviewFindingCountFromVerdict(key, verdict),
          2,
          reason: '$key should count only critical/high findings at the default threshold',
        );
      }
    });

    test('all remediation steps resolve to the executor role', () {
      const resolver = WorkflowDefinitionResolver();
      var checked = 0;

      for (final file in _builtInWorkflows) {
        final resolved = resolver.resolve(_load(file));
        for (final step in _flattenedSteps(resolved)) {
          if (step.skill != 'andthen:remediate-findings') continue;
          checked++;
          expect(step.provider, '@executor', reason: '$file → "${step.id}" should run on @executor');
          expect(step.model, '@executor', reason: '$file → "${step.id}" should use the @executor model');
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include remediation steps');
    });
  });

  group('Prompt minimality – built-in skill steps use compact invocation hints', () {
    // Skills that don't currently expose an `--auto` flag (and therefore can't
    // opt into automation-safe execution via the prompt). Keep this list tight
    // – the moment a skill grows an `--auto` flag, drop it from here so the
    // contract assertion starts enforcing automation-safety on it.
    const skillsWithoutAutoFlag = {'dartclaw-discover-andthen-spec', 'dartclaw-discover-andthen-plan'};

    test('custom skill prompts are short and automation-safe when present', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          final text = _allPromptText(step).trim();
          if (text.isEmpty) continue;

          // bash prompts are shell commands and approval prompts are human
          // messages – both legitimately prose, so guard only skill steps.
          if (step.skill == null) continue;

          final key = '$file::${step.id}';
          // Coarse blob-backstop, not a ruler: an inputs-only prompt is ≈220,
          // a pasted instruction paragraph 400+. Discipline is the real guard
          // (dartclaw_workflow/CLAUDE.md § Conventions).
          expect(text.length, lessThanOrEqualTo(280), reason: '$key prompt should stay a compact routing hint');
          if (!skillsWithoutAutoFlag.contains(step.skill)) {
            expect(text, contains('--auto'), reason: '$key prompt should opt into automation-safe skill execution');
          }
          expect(text, isNot(contains('Use the ')), reason: '$key should not repeat generic skill-selection prose');
          expect(text, isNot(contains('When the ')), reason: '$key should avoid long behavioral instruction prose');
        }
      }
    });

    test('plan-and-implement: whole-plan pass gates on gap + architecture + code,security council', () {
      final def = _load('plan-and-implement.yaml');
      final planReview = _flattenedSteps(def).firstWhere((s) => s.id == 'plan-review');
      final planReviewText = _allPromptText(planReview);
      expect(planReviewText, contains('{{context.plan}}'));
      expect(planReviewText, contains('--mode gap'));
      expect(planReviewText, contains('--auto'));

      // The code,security council runs alongside, provider-agnostic, and is
      // crash-tolerant (onFailure: continue) but still feeds the aggregator.
      final council = _flattenedSteps(def).firstWhere((s) => s.id == 'plan-review-council');
      expect(_allPromptText(council), contains('--mode code,security --council'));
      expect(council.onFailure, OnFailurePolicy.continueWorkflow);
      expect(council.skill, 'andthen:review');

      // The top-level remediation re-review uses the combined gap,code,security
      // mode (no council).
      final reReview = _flattenedSteps(def).firstWhere((s) => s.id == 're-review');
      expect(_allPromptText(reReview), contains('--mode gap,code,security'));
      expect(_allPromptText(reReview), isNot(contains('--council')));
    });

    test('andthen:review steps pin reports to the host-owned step artifacts dir', () {
      var checked = 0;
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def).where((s) => s.skill == 'andthen:review')) {
          checked++;
          expect(
            _allPromptText(step),
            contains('--output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"'),
            reason: '$file → "${step.id}" should avoid heuristic review report placement',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include andthen:review steps');
    });

    test('andthen:architecture review steps pin reports to the host-owned step artifacts dir', () {
      // Without --output-dir, andthen:architecture defaults OUTPUT_DIR to
      // docs/research/ – outside the step artifacts dir the host captures
      // review-report paths from.
      final definitions = <String, WorkflowDefinition>{
        for (final file in _builtInWorkflows) file: _load(file),
        for (final file in const [
          'spec-and-implement-inline.yaml',
          'plan-and-implement-inline.yaml',
          'review-and-remediate-inline.yaml',
        ])
          file: _loadInline(file),
      };
      var checked = 0;
      for (final entry in definitions.entries) {
        for (final step in _flattenedSteps(entry.value).where((s) => s.skill == 'andthen:architecture')) {
          checked++;
          expect(
            _allPromptText(step),
            contains('--output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"'),
            reason: '${entry.key} → "${step.id}" must write architecture review reports into the step artifacts dir',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'workflows must include andthen:architecture review steps');
    });

    test('plan-and-implement: per-story result output classifies sibling failures as non-blocking', () {
      // Regression for #4 (2026-04-24 log): S02 implement returned needsInput
      // when scoped tests passed but the full suite was red on the sibling
      // S01 behavior. Keep the classification in the output contract rather
      // than a long step prompt.
      final def = _load('plan-and-implement.yaml');
      final implement = _flattenedSteps(def).firstWhere((s) => s.id == 'implement');
      final output = implement.outputs!['story_result']!;
      expect(output.presetName, 'narrative_text');
      expect(outputResolverFor('story_result', output), isA<InlineOutput>());

      final rendered = SkillPromptBuilder.formatContextSummary(
        {'story_result': 'ok'},
        outputConfigs: {'story_result': output},
      );
      expect(rendered, contains('unrelated sibling or baseline failures are non-blocking'));
    });

    test('plan-and-implement: plan outputs describe JSON-first plan artifacts', () {
      final def = _load('plan-and-implement.yaml');
      final discover = _flattenedSteps(def).firstWhere((s) => s.id == 'discover-plan-state');
      final plan = _flattenedSteps(def).firstWhere((s) => s.id == 'plan');

      for (final output in [discover.outputs!['plan']!, plan.outputs!['plan']!]) {
        final description = _effectiveDescription(output) ?? '';
        expect(description, contains('plan.json'));
        expect(description, contains('plan.md'));
      }

      for (final step in [discover, plan]) {
        final resolver =
            outputResolverFor('technical_research', step.outputs!['technical_research']) as FileSystemOutput;
        expect(resolver.matches('docs/plans/p/.technical-research.md'), isTrue);
      }
    });

    test('migrated path outputs route through canonical presets', () {
      final definitions = <String, WorkflowDefinition>{
        for (final file in _builtInWorkflows) file: _load(file),
        for (final file in _inlineWorkflows) file: _loadInline(file),
      };

      for (final entry in definitions.entries) {
        final architectureReview = _flattenedSteps(entry.value).where((step) => step.id == 'architecture-review');
        for (final step in architectureReview) {
          final output = step.outputs!['architecture-review.review_report_path']!;
          expect(output.format, OutputFormat.path, reason: '${entry.key} → architecture-review output format');
          expect(
            output.presetName,
            'review_report_path',
            reason: '${entry.key} → architecture-review uses canonical preset',
          );
          expect(_effectiveDescription(output), contains('project-root-relative'), reason: entry.key);
        }
      }

      for (final file in ['spec-and-implement.yaml', 'spec-and-implement-inline.yaml']) {
        final def = file.endsWith('-inline.yaml') ? _loadInline(file) : _load(file);
        final detect = _flattenedSteps(def).firstWhere((step) => step.id == 'detect-spec-input');
        final output = detect.outputs!['spec_path']!;
        expect(output.format, OutputFormat.path, reason: '$file → detect-spec-input.spec_path');
        expect(output.presetName, isNull, reason: '$file → detect-spec-input uses inline output shape');
        expect(_effectiveDescription(output), contains('empty when input requires spec synthesis'), reason: file);
      }
    });

    test('discovery steps do not declare outputExamples – DC-native skill owns the example body', () {
      // outputExamples on the workflow YAML is reserved for custom workflows
      // extending a non-DC-native skill's output contract. For DC-native skills
      // like dartclaw-discover-andthen-{plan,spec}, the example lives in SKILL.md
      // alongside the contract description (single source).
      final definitions = <String, WorkflowDefinition>{
        'plan-and-implement.yaml': _load('plan-and-implement.yaml'),
        'spec-and-implement.yaml': _load('spec-and-implement.yaml'),
        'plan-and-implement-inline.yaml': _loadInline('plan-and-implement-inline.yaml'),
        'spec-and-implement-inline.yaml': _loadInline('spec-and-implement-inline.yaml'),
      };

      for (final entry in definitions.entries) {
        final step = _flattenedSteps(entry.value).first;
        expect(step.outputExamples, anyOf(isNull, isEmpty), reason: entry.key);
      }
    });
  });

  group('Variable passthrough – authored inputs reach only the steps that need them', () {
    test('no template-referenced key is redundantly declared as input/workflowVariables', () {
      var checked = 0;
      final definitions = <String, WorkflowDefinition>{
        for (final file in _builtInWorkflows) file: _load(file),
        for (final file in const [
          'spec-and-implement-inline.yaml',
          'plan-and-implement-inline.yaml',
          'review-and-remediate-inline.yaml',
        ])
          file: _loadInline(file),
      };
      for (final entry in definitions.entries) {
        for (final step in _flattenedSteps(entry.value)) {
          if (step.skill == null) continue;
          checked++;
          final offenders = _redundantlyDeclaredKeys(
            promptText: _allPromptText(step),
            inputs: step.inputs,
            variables: step.workflowVariables,
          );
          expect(
            offenders,
            isEmpty,
            reason:
                '${entry.key} → "${step.id}" declares template-referenced key(s) $offenders as input/workflowVariables '
                '(redundant no-op – the value is already interpolated inline)',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'workflows must include skill steps');

      // Seeded violations: a step that both declares and inline-references a key
      // is flagged (proving the rule is not vacuously true).
      expect(
        _redundantlyDeclaredKeys(promptText: '--auto {{context.spec_path}}', inputs: ['spec_path'], variables: []),
        contains('spec_path'),
      );
      expect(
        _redundantlyDeclaredKeys(promptText: '--auto {{FEATURE}}', inputs: [], variables: ['FEATURE']),
        contains('FEATURE'),
      );
    });

    test('plan-and-implement: only discover-plan-state opts in to FEATURE', () {
      final def = _load('plan-and-implement.yaml');
      for (final step in _flattenedSteps(def)) {
        final opts = step.workflowVariables;
        if (step.id == 'discover-plan-state') {
          expect(opts, contains('FEATURE'));
          continue;
        }
        expect(opts, isNot(contains('FEATURE')), reason: 'step "${step.id}" must not opt in to FEATURE');
      }
    });

    test('plan-and-implement: no non-discovery step references {{FEATURE}} in prompt text', () {
      final def = _load('plan-and-implement.yaml');
      final engine = WorkflowTemplateEngine();
      for (final step in _flattenedSteps(def)) {
        if (step.id == 'discover-plan-state') continue;
        final text = _allPromptText(step);
        if (text.isEmpty) continue;
        final refs = engine.extractVariableReferences(text);
        expect(refs, isNot(contains('FEATURE')), reason: 'step "${step.id}" must not reference {{FEATURE}}');
        expect(text, isNot(contains('<FEATURE>')), reason: 'step "${step.id}" must not inline a <FEATURE> block');
      }
    });

    test('spec-and-implement: only detect-spec-input opts in to FEATURE', () {
      // The `spec` step interpolates {{FEATURE}} inline by design, so its
      // workflowVariables opt-in would be a redundant no-op – only the read-only
      // detect-spec-input classifier auto-frames FEATURE as untrusted data.
      final def = _load('spec-and-implement.yaml');
      for (final step in _flattenedSteps(def)) {
        final opts = step.workflowVariables;
        if (step.id == 'detect-spec-input') {
          expect(opts, contains('FEATURE'));
          continue;
        }
        expect(opts, isNot(contains('FEATURE')), reason: 'step "${step.id}" must not opt in to FEATURE');
      }
    });

    test('spec-and-implement: no non-detection/spec step references {{FEATURE}} in prompt text', () {
      final def = _load('spec-and-implement.yaml');
      final engine = WorkflowTemplateEngine();
      for (final step in _flattenedSteps(def)) {
        if (step.id == 'detect-spec-input' || step.id == 'spec') continue;
        final text = _allPromptText(step);
        if (text.isEmpty) continue;
        final refs = engine.extractVariableReferences(text);
        expect(refs, isNot(contains('FEATURE')));
        expect(text, isNot(contains('<FEATURE>')));
      }
    });

    test('code-review: no step opts in to TARGET/BRANCH/PR_NUMBER/BASE_BRANCH (all inline by design)', () {
      // review-code and re-review both interpolate these variables inline as the
      // review target framing, so a workflowVariables opt-in would be a redundant
      // no-op (no-op-inputs rule); they are workflow-declared variables, not
      // auto-framed untrusted data.
      final def = _load('code-review.yaml');
      const reviewInputs = ['TARGET', 'BRANCH', 'PR_NUMBER', 'BASE_BRANCH'];
      for (final step in _flattenedSteps(def)) {
        for (final v in reviewInputs) {
          expect(step.workflowVariables, isNot(contains(v)), reason: 'step "${step.id}" must not opt in to $v');
        }
      }
    });
  });

  group('Output schema coherence', () {
    test('new output presets are registered with canonical descriptions', () {
      expect(schemaPresets['gating_findings_count']?.format, OutputFormat.json);
      expect(schemaPresets['findings_count']?.format, OutputFormat.json);
      expect(schemaPresets['review_report_path']?.format, OutputFormat.path);
      expect(schemaPresets['narrative_text']?.format, OutputFormat.text);
      for (final name in const [
        'fis_path',
        'detected_fis_path',
        'spec_source',
        'spec_confidence',
        'story_result',
        'remediation_result',
        'remediation_summary',
        'prd_path',
        'plan_path',
      ]) {
        expect(schemaPresets.containsKey(name), isFalse, reason: name);
      }
    });

    test('built-in and inline workflows exercise generic shorthand presets', () {
      final defs = [
        for (final file in _builtInWorkflows) _load(file),
        for (final file in _inlineWorkflows) _loadInline(file),
      ];
      final usedPresetNames = <String>{};
      for (final def in defs) {
        for (final step in _flattenedSteps(def)) {
          usedPresetNames.addAll(
            step.outputs?.values.map((output) => output.presetName).whereType<String>() ?? const [],
          );
        }
      }

      expect(
        usedPresetNames,
        containsAll([
          'gating_findings_count',
          'findings_count',
          'review_report_path',
          'narrative_text',
          'non_negative_integer',
          'story_specs',
        ]),
      );
    });

    test('built-in inferred output plumbing matches the explicit form', () {
      // Mirrors docs/guide/workflows-reference.md § YAML Field Reference:
      // schema presets may infer format/outputMode, and format: path with
      // pathPattern infers the filesystem resolver.
      final parser = WorkflowDefinitionParser();
      final specInferred = parser.parse(_loadSource('spec-and-implement.yaml'));
      final specExplicit = parser.parse(
        _loadSource('spec-and-implement.yaml')
            .replaceAll(
              '      spec_path:\n        format: path\n',
              '      spec_path:\n        format: path\n        resolver: filesystem\n',
            )
            .replaceAll(
              '      spec_confidence:\n        schema: non_negative_integer\n',
              '      spec_confidence:\n        format: json\n        schema: non_negative_integer\n',
            ),
      );
      for (final stepId in ['detect-spec-input', 'spec']) {
        final inferred = _flattenedSteps(specInferred).singleWhere((step) => step.id == stepId);
        final explicit = _flattenedSteps(specExplicit).singleWhere((step) => step.id == stepId);
        for (final key in ['spec_path', 'spec_confidence']) {
          expect(inferred.outputs![key]!.toJson(), explicit.outputs![key]!.toJson(), reason: '$stepId.$key');
        }
      }

      final planInferred = parser.parse(_loadSource('plan-and-implement.yaml'));
      final planExplicit = parser.parse(
        _loadSource('plan-and-implement.yaml')
            .replaceAll(
              '      prd:\n        format: path\n',
              '      prd:\n        format: path\n        resolver: filesystem\n',
            )
            .replaceAll(
              '      plan:\n        format: path\n',
              '      plan:\n        format: path\n        resolver: filesystem\n',
            )
            .replaceAll(
              '      technical_research:\n        format: path\n',
              '      technical_research:\n        format: path\n        resolver: filesystem\n',
            ),
      );
      const planOutputKeys = {
        'discover-plan-state': ['prd', 'plan', 'technical_research'],
        'plan': ['plan', 'technical_research'],
      };
      for (final entry in planOutputKeys.entries) {
        final stepId = entry.key;
        final inferred = _flattenedSteps(planInferred).singleWhere((step) => step.id == stepId);
        final explicit = _flattenedSteps(planExplicit).singleWhere((step) => step.id == stepId);
        for (final key in entry.value) {
          expect(inferred.outputs![key]!.toJson(), explicit.outputs![key]!.toJson(), reason: '$stepId.$key');
        }
      }
    });

    test('built-in YAML does not restate inferable output plumbing', () {
      for (final file in const ['spec-and-implement.yaml', 'plan-and-implement.yaml']) {
        final source = _loadSource(file);
        expect(
          RegExp(r'^\s*resolver:\s*filesystem\s*$', multiLine: true).allMatches(source),
          isEmpty,
          reason: '$file should rely on format:path + pathPattern resolver inference',
        );
        expect(
          RegExp(r'^\s*format:\s*json\s*\n\s*schema:\s*non_negative_integer\s*$', multiLine: true).allMatches(source),
          isEmpty,
          reason: '$file should rely on non_negative_integer preset format inference',
        );
      }
    });

    test('every findings_count output uses a structured non-negative integer schema', () {
      final definitions = <String, WorkflowDefinition>{
        for (final file in _builtInWorkflows) file: _load(file),
        for (final file in _inlineWorkflows) file: _loadInline(file),
      };

      for (final definitionEntry in definitions.entries) {
        for (final step in _flattenedSteps(definitionEntry.value)) {
          final outputs = step.outputs;
          if (outputs == null) continue;
          for (final outputEntry in outputs.entries) {
            if (!outputEntry.key.endsWith('findings_count')) continue;
            expect(
              outputEntry.value.schema,
              isIn(['non_negative_integer', 'findings_count', 'gating_findings_count']),
              reason:
                  '${definitionEntry.key} → "${step.id}".${outputEntry.key} must use a registered non-negative integer schema',
            );
            expect(
              outputEntry.value.outputMode,
              OutputMode.structured,
              reason:
                  '${definitionEntry.key} → "${step.id}".${outputEntry.key} must preserve strict structured count validation',
            );
          }
        }
      }
    });

    test('discovery steps declare framework-neutral output validation (structured story_specs + format: path)', () {
      // ADR-041: the engine validates discovery output with only declared
      // schema (outputMode: structured) and generic format: path. These
      // declarations are what the un-gated generic validators key on — the
      // bespoke dartclaw-discover-andthen-* validators are no longer wired into
      // the dispatch path. Locking the declarations here keeps the generic path
      // load-bearing.
      final planDefs = <String, WorkflowDefinition>{
        'plan-and-implement.yaml': _load('plan-and-implement.yaml'),
        'plan-and-implement-inline.yaml': _loadInline('plan-and-implement-inline.yaml'),
      };
      for (final entry in planDefs.entries) {
        final discover = _flattenedSteps(entry.value).firstWhere((s) => s.id == 'discover-plan-state');
        final storySpecs = discover.outputs!['story_specs']!;
        expect(storySpecs.presetName, 'story_specs', reason: '${entry.key} → discover-plan-state story_specs preset');
        expect(storySpecs.format, OutputFormat.json, reason: '${entry.key} → story_specs format');
        expect(
          storySpecs.outputMode,
          OutputMode.structured,
          reason: '${entry.key} → story_specs must be schema-validated (outputMode: structured)',
        );
        expect(storySpecs.hasSchema, isTrue, reason: '${entry.key} → story_specs carries a schema');
        for (final key in ['prd', 'plan']) {
          expect(
            discover.outputs![key]!.format,
            OutputFormat.path,
            reason: '${entry.key} → discover-plan-state $key is format: path',
          );
        }
      }

      final specDefs = <String, WorkflowDefinition>{
        'spec-and-implement.yaml': _load('spec-and-implement.yaml'),
        'spec-and-implement-inline.yaml': _loadInline('spec-and-implement-inline.yaml'),
      };
      for (final entry in specDefs.entries) {
        final detect = _flattenedSteps(entry.value).firstWhere((s) => s.id == 'detect-spec-input');
        expect(
          detect.outputs!['spec_path']!.format,
          OutputFormat.path,
          reason: '${entry.key} → detect-spec-input.spec_path is format: path',
        );
        expect(
          outputResolverFor('spec_source', detect.outputs!['spec_source']),
          isA<InlineOutput>(),
          reason: '${entry.key} → detect-spec-input.spec_source narrative resolver',
        );
      }
    });

    test('detect-spec-input main prompt retains spec_source and drops finalizer-covered keys (TD-114)', () {
      final specDefs = <String, WorkflowDefinition>{
        'spec-and-implement.yaml': _load('spec-and-implement.yaml'),
        'spec-and-implement-inline.yaml': _loadInline('spec-and-implement-inline.yaml'),
      };
      for (final entry in specDefs.entries) {
        final detect = _flattenedSteps(entry.value).firstWhere((s) => s.id == 'detect-spec-input');
        expect(stepNeedsFinalizer(detect, detect.outputs), isTrue, reason: '${entry.key} → mixed finalizer step');
        final covered = modelDerivedFinalizerKeys(detect, detect.outputs);
        expect(covered, containsAll(const ['spec_path', 'spec_confidence']), reason: '${entry.key} → covered set');
        expect(covered, isNot(contains('spec_source')), reason: '${entry.key} → spec_source stays host-owned');

        final prompt = const PromptAugmenter().augment(
          'classify',
          outputs: detect.outputs,
          outputKeys: detect.outputKeys,
          finalizerCoveredKeys: covered,
        );
        expect(prompt, contains('## Workflow Output Contract'), reason: '${entry.key} → contract rendered');
        expect(prompt, contains('"spec_source"'), reason: '${entry.key} → spec_source instructed');
        expect(prompt, isNot(contains('"spec_path"')), reason: '${entry.key} → spec_path rides the envelope');
        expect(
          prompt,
          isNot(contains('"spec_confidence"')),
          reason: '${entry.key} → spec_confidence rides the envelope',
        );
        expect(
          prompt,
          isNot(contains('## Step Outcome Protocol')),
          reason: '${entry.key} → outcome rides the envelope',
        );
      }
    });

    test('every step that declares outputs entries declares a format on each one', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          final outputs = step.outputs;
          if (outputs == null) continue;
          for (final entry in outputs.entries) {
            expect(
              entry.value.format,
              isNotNull,
              reason: '$file → "${step.id}".${entry.key} outputs entry must declare a format',
            );
          }
        }
      }
    });
  });

  group('Review output-key naming convention', () {
    // Locks the cross-workflow naming convention documented in
    // docs/guide/workflows.md § Review Output-Key Convention: the key
    // `review_report_path` (bare or `<stepId>.review_report_path`) means a
    // review-report path, and the remediation gate value is named
    // `gating_findings_count` — never a `verdict`-shaped gate. A future edit
    // that reintroduces `review_report_path` as a verdict findings object, or
    // re-points a loop gate, fails here.
    Map<String, WorkflowDefinition> conventionDefinitions() => {
      for (final file in _builtInWorkflows) file: _load(file),
      for (final file in const [
        'spec-and-implement-inline.yaml',
        'plan-and-implement-inline.yaml',
        'review-and-remediate-inline.yaml',
      ])
        file: _loadInline(file),
    };

    bool isReviewReportPathKey(String key) => key == 'review_report_path' || key.endsWith('.review_report_path');

    test('every review_report_path output key carries the review-report-path preset', () {
      var checked = 0;
      for (final entry in conventionDefinitions().entries) {
        for (final step in _flattenedSteps(entry.value)) {
          for (final output in step.outputs?.entries ?? const <MapEntry<String, OutputConfig>>[]) {
            if (!isReviewReportPathKey(output.key)) continue;
            checked++;
            expect(
              output.value.format,
              OutputFormat.path,
              reason: '${entry.key} → "${step.id}".${output.key} must declare format: path (review-report path)',
            );
            expect(
              output.value.presetName,
              'review_report_path',
              reason:
                  '${entry.key} → "${step.id}".${output.key} must use the review_report_path preset, not a verdict/findings shape',
            );
          }
        }
      }
      expect(checked, greaterThan(0), reason: 'workflows must declare review_report_path outputs');
    });

    test('no step binds a review_report_path key to a non-path preset', () {
      const verdictishPresets = {'verdict', 'findings_count', 'gating_findings_count', 'non_negative_integer'};
      for (final entry in conventionDefinitions().entries) {
        for (final step in _flattenedSteps(entry.value)) {
          for (final output in step.outputs?.entries ?? const <MapEntry<String, OutputConfig>>[]) {
            if (!isReviewReportPathKey(output.key)) continue;
            expect(
              verdictishPresets,
              isNot(contains(output.value.presetName)),
              reason:
                  '${entry.key} → "${step.id}".${output.key} binds the review_report_path name to a non-path preset "${output.value.presetName}"',
            );
          }
        }
      }
    });

    test('remediation loop gates name gating_findings_count, never a verdict gate', () {
      var checked = 0;
      for (final entry in conventionDefinitions().entries) {
        for (final loop in entry.value.loops) {
          if (loop.id != 'remediation-loop' && loop.id != 'story-remediation') continue;
          checked++;
          for (final gate in [loop.entryGate, loop.exitGate]) {
            if (gate == null) continue;
            expect(
              gate,
              contains('gating_findings_count'),
              reason: '${entry.key} → loop "${loop.id}" gate must read gating_findings_count: "$gate"',
            );
            expect(
              gate,
              isNot(contains('verdict')),
              reason: '${entry.key} → loop "${loop.id}" gate must not branch on a verdict field: "$gate"',
            );
          }
        }
      }
      expect(checked, greaterThan(0), reason: 'built-in + inline workflows must include remediation loops');
    });
  });
}
