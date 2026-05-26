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

WorkflowDefinition _loadInline(String fileName) {
  final dir = findAncestorDir(['dev/tools/dartclaw-workflows/custom-workflows']);
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
          if (step.type != WorkflowTaskType.agent) continue;
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

    test('plan-and-implement simplifies inside each story after quick-review', () {
      final def = _load('plan-and-implement.yaml');
      expect(_flattenedSteps(def).where((step) => step.id == 'refactor'), isEmpty);
      expect(_flattenedSteps(def).where((step) => step.skill == 'andthen:simplify-code'), hasLength(1));

      final storyPipeline = def.nodes.whereType<ForeachNode>().singleWhere((node) => node.stepId == 'story-pipeline');
      final stepIds = storyPipeline.childStepIds;
      expect(stepIds.indexOf('simplify-code'), stepIds.indexOf('quick-review') + 1);

      final simplify = _flattenedSteps(def).singleWhere((step) => step.id == 'simplify-code');
      expect(simplify.skill, 'andthen:simplify-code');
      expect(simplify.provider, '@executor');
      expect(simplify.model, '@executor');
      expect(simplify.continueSession, '@previous');
      expect(simplify.inputs, ['story_result']);
      expect(_allPromptText(simplify), contains('changes for this story'));
    });

    test('spec-and-implement simplifies once between implement and reviews', () {
      final def = _load('spec-and-implement.yaml');
      expect(_flattenedSteps(def).where((step) => step.id == 'refactor'), isEmpty);

      final stepIds = def.steps.map((step) => step.id).toList();
      expect(stepIds.indexOf('simplify-code'), stepIds.indexOf('implement') + 1);
      expect(stepIds.indexOf('integrated-review'), greaterThan(stepIds.indexOf('simplify-code')));

      final simplify = def.steps.singleWhere((step) => step.id == 'simplify-code');
      expect(simplify.skill, 'andthen:simplify-code');
      expect(simplify.provider, '@executor');
      expect(simplify.model, '@executor');
      expect(simplify.inputs, isEmpty);
      expect(_allPromptText(simplify), contains('current branch'));
    });

    test('inline spec simplify-code scopes by FIS, not by base ref', () {
      final def = _loadInline('spec-and-implement-inline.yaml');
      final simplify = def.steps.singleWhere((step) => step.id == 'simplify-code');
      final prompt = _allPromptText(simplify);

      expect(simplify.provider, '@executor');
      expect(simplify.model, '@executor');
      expect(simplify.inputs, ['spec_path']);
      expect(prompt, contains('{{context.spec_path}}'));
      expect(prompt, contains('live checkout'));
      expect(prompt, isNot(contains('base ref')));
      expect(prompt, isNot(contains('current branch')));
    });

    test('inline plan-and-implement mirrors the per-story simplify-code shape', () {
      final def = _loadInline('plan-and-implement-inline.yaml');
      expect(_flattenedSteps(def).where((step) => step.id == 'refactor'), isEmpty);
      expect(_flattenedSteps(def).where((step) => step.skill == 'andthen:simplify-code'), hasLength(1));

      final storyPipeline = def.nodes.whereType<ForeachNode>().singleWhere((node) => node.stepId == 'story-pipeline');
      final stepIds = storyPipeline.childStepIds;
      expect(stepIds.indexOf('simplify-code'), stepIds.indexOf('quick-review') + 1);

      final simplify = _flattenedSteps(def).singleWhere((step) => step.id == 'simplify-code');
      expect(simplify.skill, 'andthen:simplify-code');
      expect(simplify.provider, '@executor');
      expect(simplify.model, '@executor');
      expect(simplify.continueSession, '@previous');
      expect(simplify.inputs, ['story_result']);
      expect(_allPromptText(simplify), contains('changes for this story'));
    });
  });

  group('Tool permissions – review steps match their output contract', () {
    // Structured review steps declare an explicit allowlist with `file_write`
    // absent so step_config_policy.stepIsReadOnly returns true. File-backed
    // review steps need `file_write`; they emit a path to a report artifact
    // that the workflow validates against the task worktree.
    const writeableReviewSteps = {'quick-review'};

    test('review steps declare tool access consistent with artifact outputs', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (!step.id.contains('review')) continue;
          if (step.type == WorkflowTaskType.aggregateReviews) continue;
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

    test('remediation steps pass at least one report path source and declare it', () {
      final reportKeys = {'review_findings', 'architecture_review_findings'};
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
          for (final ref in references) {
            expect(step.inputs, contains(ref), reason: '$file → "${step.id}" must declare report path input "$ref"');
          }
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include remediation steps');
    });

    test('andthen:review report outputs direct writes into the runtime artifacts dir', () {
      var checked = 0;
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          if (step.skill != 'andthen:review') continue;
          final reviewFindings = step.outputs?['review_findings'];
          if (reviewFindings == null) continue;
          checked++;
          expect(
            _allPromptText(step),
            contains('--output-dir "{{workflow.runtime_artifacts_dir}}/reviews"'),
            reason: '$file → "${step.id}" must write review reports under workflow runtime artifacts',
          );
          final description = _effectiveDescription(reviewFindings) ?? '';
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

    test('parallel review workflows aggregate first-pass findings and re-review overwrites simple names', () {
      final expectedSources = {
        'spec-and-implement.yaml': ['integrated-review', 'architecture-review'],
        'plan-and-implement.yaml': ['plan-review', 'architecture-review'],
        'spec-and-implement-inline.yaml': ['integrated-review', 'architecture-review'],
        'plan-and-implement-inline.yaml': ['plan-review', 'architecture-review'],
      };

      for (final entry in expectedSources.entries) {
        final file = entry.key;
        final def = file.endsWith('-inline.yaml') ? _loadInline(file) : _load(file);
        final aggregate = _flattenedSteps(def).firstWhere((s) => s.id == 'review-aggregate');
        final loop = def.loops.firstWhere((l) => l.id == 'remediation-loop');
        final remediate = _flattenedSteps(def).firstWhere((s) => s.id == 'remediate');
        final reReview = _flattenedSteps(def).firstWhere((s) => s.id == 're-review');

        expect(aggregate.type, WorkflowTaskType.aggregateReviews, reason: '$file → review-aggregate type');
        expect(aggregate.aggregateReviews, entry.value, reason: '$file → aggregate source order');
        expect(aggregate.outputKeys.toSet(), {'review_findings', 'findings_count', 'gating_findings_count'});
        expect(loop.entryGate, 'gating_findings_count > 0', reason: '$file → loop entry gate');
        expect(loop.exitGate, 'gating_findings_count == 0', reason: '$file → loop exit gate');
        expect(remediate.entryGate, 'gating_findings_count > 0', reason: '$file → remediate entry gate');
        expect(remediate.inputs, contains('review_findings'), reason: '$file → remediate report input');
        expect(remediate.inputs, isNot(contains('architecture_review_findings')), reason: file);
        expect(_allPromptText(remediate).trim(), '--auto {{context.review_findings}}', reason: file);
        expect(
          remediate.outputs?.containsKey('architecture-review.gating_findings_count'),
          isNot(isTrue),
          reason: file,
        );
        expect(remediate.outputs?.containsKey('architecture_review_findings'), isNot(isTrue), reason: file);
        expect(remediate.outputs?.containsKey('diff_summary'), isNot(isTrue), reason: file);
        expect(reReview.outputKeys, containsAll(['review_findings', 'findings_count', 'gating_findings_count']));
        expect(reReview.outputKeys, isNot(contains('re-review.findings_count')), reason: file);
        expect(reReview.outputKeys, isNot(contains('re-review.gating_findings_count')), reason: file);
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

          final key = '$file::${step.id}';
          expect(text.length, lessThanOrEqualTo(180), reason: '$key prompt should stay a compact routing hint');
          // Bash and approval steps don't drive a skill – their prompt is a
          // shell command or a checkpoint message and has no `--auto`
          // contract.
          if (step.skill != null && !skillsWithoutAutoFlag.contains(step.skill)) {
            expect(text, contains('--auto'), reason: '$key prompt should opt into automation-safe skill execution');
          }
          expect(text, isNot(contains('Use the ')), reason: '$key should not repeat generic skill-selection prose');
          expect(text, isNot(contains('When the ')), reason: '$key should avoid long behavioral instruction prose');
        }
      }
    });

    test('plan-and-implement: plan-review targets the plan with mixed review mode', () {
      final def = _load('plan-and-implement.yaml');
      final planReview = _flattenedSteps(def).firstWhere((s) => s.id == 'plan-review');
      final text = _allPromptText(planReview);
      expect(text, contains('{{context.plan}}'));
      expect(text, contains('--mode mixed'));
      expect(text, contains('--auto'));
    });

    test('andthen:review steps pin reports to workflow runtime artifacts dir', () {
      var checked = 0;
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def).where((s) => s.skill == 'andthen:review')) {
          checked++;
          expect(
            _allPromptText(step),
            contains('--output-dir "{{workflow.runtime_artifacts_dir}}/reviews'),
            reason: '$file → "${step.id}" should avoid heuristic review report placement',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include andthen:review steps');
    });

    test('plan-and-implement: per-story result output classifies sibling failures as non-blocking', () {
      // Regression for #4 (2026-04-24 log): S02 implement returned needsInput
      // when scoped tests passed but the full suite was red on the sibling
      // S01 behavior. Keep the classification in the output contract rather
      // than a long step prompt.
      final def = _load('plan-and-implement.yaml');
      final implement = _flattenedSteps(def).firstWhere((s) => s.id == 'implement');
      final output = implement.outputs!['story_result']!;
      expect(output.schema, equals('story_result'));
      expect(output.description, isNull);

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
    });

    test('migrated path outputs route through canonical presets', () {
      final definitions = <String, WorkflowDefinition>{
        for (final file in _builtInWorkflows) file: _load(file),
        for (final file in _inlineWorkflows) file: _loadInline(file),
      };

      for (final entry in definitions.entries) {
        final architectureReview = _flattenedSteps(entry.value).where((step) => step.id == 'architecture-review');
        for (final step in architectureReview) {
          final output = step.outputs!['architecture_review_findings']!;
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
        expect(
          output.presetName,
          'detected_fis_path',
          reason: '$file → detect-spec-input uses canonical optional-path preset',
        );
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

    test('spec-and-implement: only detect-spec-input and spec opt in to FEATURE', () {
      final def = _load('spec-and-implement.yaml');
      for (final step in _flattenedSteps(def)) {
        final opts = step.workflowVariables;
        if (step.id == 'detect-spec-input' || step.id == 'spec') {
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

    test('code-review: only review-code opts in to TARGET/BRANCH/PR_NUMBER/BASE_BRANCH', () {
      final def = _load('code-review.yaml');
      const reviewInputs = ['TARGET', 'BRANCH', 'PR_NUMBER', 'BASE_BRANCH'];
      for (final step in _flattenedSteps(def)) {
        if (step.id == 'review-code') {
          for (final v in reviewInputs) {
            expect(step.workflowVariables, contains(v));
          }
          continue;
        }
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
      expect(schemaPresets['prd_path']?.description, 'Workspace-relative path to the required PRD on disk.');
      expect(schemaPresets['plan_path']?.description, contains('plan.json'));
      expect(schemaPresets['fis_path']?.description, contains('FIS on disk'));
    });

    test('built-in and inline workflows exercise the new shorthand presets', () {
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
          'prd_path',
          'plan_path',
          'fis_path',
          'detected_fis_path',
          'spec_source',
          'spec_confidence',
          'story_specs',
        ]),
      );
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
}
