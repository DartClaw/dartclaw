// Systematic prompt and structural contract suite for the three built-in
// workflow definitions (spec-and-implement, plan-and-implement, code-review).
//
// These tests are invariants — they assert properties that must hold for every
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
//    write, discover-project is read-only.
//  * Prompt minimality: step prompts are compact invocation hints that name
//    the skill input and automation flags, not long instruction blocks.
//  * Variable passthrough: authored input variables (FEATURE/REQUIREMENTS/
//    TARGET) leak into at most the steps that need them.
//
// Tests that assert behavior the current YAML does NOT yet satisfy are marked
// with a `skip:` and an explicit open-issue reference. They fire the moment
// the YAML is tightened, preventing silent regressions.
library;

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _definitionsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'lib', 'src', 'workflow', 'definitions'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
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

const _builtInWorkflows = ['spec-and-implement.yaml', 'plan-and-implement.yaml', 'code-review.yaml'];

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
          if (step.type != 'agent') continue;
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

    test('workflows that author artifacts start with discover-project', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        expect(
          def.steps.first.id,
          'discover-project',
          reason: '$file must begin with discover-project so the project_index context is available',
        );
        expect(def.steps.first.skill, 'dartclaw-discover-project');
      }
    });
  });

  group('Tool permissions — review steps match their output contract', () {
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

    test('discover-project is read-only', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        final discover = def.steps.firstWhere((s) => s.id == 'discover-project');
        expect(discover.allowedTools, isNotNull);
        expect(
          discover.allowedTools,
          isNot(contains('file_write')),
          reason: '$file → discover-project must never include file_write',
        );
      }
    });

    test('remediation steps pass exactly one report path source', () {
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
            hasLength(1),
            reason: '$file → "${step.id}" must pass one report path to andthen:remediate-findings',
          );
          expect(
            step.inputs,
            contains(references.single),
            reason: '$file → "${step.id}" must declare its report path input',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include remediation steps');
    });

    test('andthen:review report outputs request runtime absolute paths', () {
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
          final description = reviewFindings.description ?? '';
          expect(
            description,
            contains('Absolute path'),
            reason: '$file → "${step.id}" must ask for an absolute review report path',
          );
          expect(
            description,
            contains('--output-dir'),
            reason: '$file → "${step.id}" must point the output contract at the rendered output-dir',
          );
          expect(
            description,
            isNot(contains('Workspace-relative')),
            reason: '$file → "${step.id}" must not request a worktree-relative runtime report path',
          );
        }
      }
      expect(checked, greaterThan(0), reason: 'built-ins must include file-backed andthen:review steps');
    });

    test('split remediation loops consume fresh re-review reports after the first pass', () {
      for (final file in ['spec-and-implement.yaml', 'plan-and-implement.yaml']) {
        final def = _load(file);
        final remediate = _flattenedSteps(def).firstWhere((s) => s.id == 'remediate');
        final remediateArchitecture = _flattenedSteps(def).firstWhere((s) => s.id == 'remediate-architecture');

        expect(
          remediate.entryGate,
          contains('re-review.gating_findings_count > 0'),
          reason: '$file → remediate must consume the latest re-review report on later loop iterations',
        );
        expect(
          remediateArchitecture.entryGate,
          contains('loop.remediation-loop.iteration == 1'),
          reason: '$file → architecture remediation must not keep consuming the initial architecture report',
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

  group('Prompt minimality — built-in skill steps use compact invocation hints', () {
    // Skills that don't currently expose an `--auto` flag (and therefore can't
    // opt into automation-safe execution via the prompt). Keep this list tight
    // — the moment a skill grows an `--auto` flag, drop it from here so the
    // contract assertion starts enforcing automation-safety on it.
    const skillsWithoutAutoFlag = {'dartclaw-discover-project', 'andthen:refactor'};

    test('custom skill prompts are short and automation-safe when present', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          final text = _allPromptText(step).trim();
          if (text.isEmpty) continue;

          final key = '$file::${step.id}';
          expect(text.length, lessThanOrEqualTo(180), reason: '$key prompt should stay a compact routing hint');
          if (!skillsWithoutAutoFlag.contains(step.skill)) {
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
            contains('--output-dir "{{workflow.runtime_artifacts_dir}}/reviews"'),
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
      expect(output.schema, equals('story-result'));
      expect(output.description, isNull);

      final rendered = SkillPromptBuilder.formatContextSummary(
        {'story_result': 'ok'},
        outputConfigs: {'story_result': output},
      );
      expect(rendered, contains('unrelated sibling or baseline failures are non-blocking'));
    });
  });

  group('Variable passthrough — authored inputs reach only the steps that need them', () {
    test('plan-and-implement: only discover-project and prd opt in to REQUIREMENTS', () {
      final def = _load('plan-and-implement.yaml');
      for (final step in _flattenedSteps(def)) {
        final opts = step.workflowVariables;
        if (step.id == 'discover-project' || step.id == 'prd') {
          expect(opts, contains('REQUIREMENTS'));
          continue;
        }
        expect(opts, isNot(contains('REQUIREMENTS')), reason: 'step "${step.id}" must not opt in to REQUIREMENTS');
      }
    });

    test('plan-and-implement: no non-prd step references {{REQUIREMENTS}} in prompt text', () {
      final def = _load('plan-and-implement.yaml');
      final engine = WorkflowTemplateEngine();
      for (final step in _flattenedSteps(def)) {
        if (step.id == 'prd') continue;
        final text = _allPromptText(step);
        if (text.isEmpty) continue;
        final refs = engine.extractVariableReferences(text);
        expect(refs, isNot(contains('REQUIREMENTS')), reason: 'step "${step.id}" must not reference {{REQUIREMENTS}}');
        expect(
          text,
          isNot(contains('<REQUIREMENTS>')),
          reason: 'step "${step.id}" must not inline a <REQUIREMENTS> block',
        );
      }
    });

    test('spec-and-implement: only discover-project and spec opt in to FEATURE', () {
      final def = _load('spec-and-implement.yaml');
      for (final step in _flattenedSteps(def)) {
        final opts = step.workflowVariables;
        if (step.id == 'discover-project' || step.id == 'spec') {
          expect(opts, contains('FEATURE'));
          continue;
        }
        expect(opts, isNot(contains('FEATURE')), reason: 'step "${step.id}" must not opt in to FEATURE');
      }
    });

    test('spec-and-implement: no non-spec step references {{FEATURE}} in prompt text', () {
      final def = _load('spec-and-implement.yaml');
      final engine = WorkflowTemplateEngine();
      for (final step in _flattenedSteps(def)) {
        if (step.id == 'spec') continue;
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
    test('every findings_count output uses the non-negative-integer schema', () {
      for (final file in _builtInWorkflows) {
        final def = _load(file);
        for (final step in _flattenedSteps(def)) {
          final outputs = step.outputs;
          if (outputs == null) continue;
          for (final entry in outputs.entries) {
            if (!entry.key.endsWith('findings_count')) continue;
            expect(
              entry.value.schema,
              'non-negative-integer',
              reason: '$file → "${step.id}".${entry.key} must use the non-negative-integer schema',
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
