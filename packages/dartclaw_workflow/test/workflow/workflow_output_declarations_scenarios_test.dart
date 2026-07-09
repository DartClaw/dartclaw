// Acceptance-scenario coverage for the "Workflow Output Declarations and
// Contract Hygiene" story (S01–S05). Complements the invariant assertions in
// built_in_workflow_contracts_test.dart with behavior-level proofs that the
// generic-preset conversions and re-review target fix preserve resolution,
// envelope, prompt-framing, and glob behavior.
library;

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/execution_envelope_schema.dart' show buildExecutionEnvelopeSchema;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_support/workflow_test_paths.dart';

WorkflowDefinition _load(String fileName) =>
    WorkflowDefinitionParser().parse(File(p.join(workflowDefinitionsDir(), fileName)).readAsStringSync());

/// The declared-output subobject of an execution envelope schema.
Map<String, dynamic> _envelopeOutputs(Map<String, dynamic> envelope) =>
    ((envelope['properties'] as Map)['outputs'] as Map)['properties'] as Map<String, dynamic>;

void main() {
  group('S01 – schema: narrative_text keeps inline resolution', () {
    // Object form: schema: narrative_text + inline description (no resolver, no
    // inline schema). Parsed from a one-off definition mirroring the shipped
    // conversion.
    const yaml = '''
name: s01-probe
description: probe
steps:
  - id: emit
    name: Emit
    skill: andthen:review
    prompt: "--auto"
    outputs:
      remediation_summary:
        schema: narrative_text
        description: Summary of what was changed during this remediation pass.
''';

    final def = WorkflowDefinitionParser().parse(yaml);
    final config = def.steps.single.outputs!['remediation_summary']!;

    test('resolves InlineOutput', () {
      expect(outputResolverFor('remediation_summary', config), isA<InlineOutput>());
    });

    test('joins the strict structured-output envelope as a string field', () {
      final envelope = buildExecutionEnvelopeSchema(def.steps.single, def.steps.single.outputs)!;
      final outputs = (envelope['properties'] as Map)['outputs'] as Map;
      expect((outputs['required'] as List), contains('remediation_summary'));
      expect(_envelopeOutputs(envelope)['remediation_summary'], containsPair('type', 'string'));
    });

    test('augmented prompt renders the inline description', () {
      final augmented = const PromptAugmenter().augment(
        '--auto',
        outputs: def.steps.single.outputs,
        outputKeys: def.steps.single.outputKeys,
      );
      expect(augmented, contains('Summary of what was changed during this remediation pass.'));
      expect(PromptAugmenter.effectiveDescription(config), 'Summary of what was changed during this remediation pass.');
    });

    test('round-trips through toJson/fromJson', () {
      final restored = OutputConfig.fromJson(config.toJson());
      expect(restored.presetName, 'narrative_text');
      expect(restored.format, OutputFormat.text);
      expect(restored.description, config.description);
      expect(outputResolverFor('remediation_summary', restored), isA<InlineOutput>());
    });
  });

  group('S02 – spec_confidence reuses non_negative_integer', () {
    final def = _load('spec-and-implement.yaml');
    final detect = def.steps.singleWhere((s) => s.id == 'detect-spec-input');
    final config = detect.outputs!['spec_confidence']!;

    test('carries the non_negative_integer preset association (the dropped registry link)', () {
      expect(config.presetName, 'non_negative_integer');
    });

    test('structured envelope schema preserves the prior inline field type', () {
      final envelope = buildExecutionEnvelopeSchema(detect, detect.outputs)!;
      final field = _envelopeOutputs(envelope)['spec_confidence'] as Map;
      expect(field, containsPair('type', 'integer'));
      expect(field, containsPair('minimum', 0));
    });

    test('workflow-context contract line renders the inline description', () {
      final augmented = const PromptAugmenter().augment(
        '--auto',
        outputs: detect.outputs,
        outputKeys: detect.outputKeys,
      );
      expect(augmented, contains('Self-rated 1-10 readiness'));
    });

    test('resolves InlineOutput via the preset defaultResolver', () {
      expect(outputResolverFor('spec_confidence', config), isA<InlineOutput>());
    });
  });

  group('S03 – prd/plan resolve byte-identical globs after relocation', () {
    final def = _load('plan-and-implement.yaml');
    final discover = def.steps.singleWhere((s) => s.id == 'discover-plan-state');

    test('prd resolves **/*prd.md', () {
      final resolver = outputResolverFor('prd', discover.outputs!['prd']) as FileSystemOutput;
      expect(resolver.pathPattern, '**/*prd.md');
    });

    test('plan resolves **/*plan.{json,md}', () {
      final resolver = outputResolverFor('plan', discover.outputs!['plan']) as FileSystemOutput;
      expect(resolver.pathPattern, '**/*plan.{json,md}');
    });

    test('the deleted presets are gone from the registry', () {
      expect(schemaPresets.containsKey('prd_path'), isFalse);
      expect(schemaPresets.containsKey('plan_path'), isFalse);
    });
  });

  group('S04 – per-story prompts carry only their own story context', () {
    final def = _load('plan-and-implement.yaml');

    test('implement declares no story_specs input, so no <story_specs> is auto-framed', () {
      final implement = def.steps.singleWhere((s) => s.id == 'implement');
      expect(implement.inputs, isNot(contains('story_specs')));
      final framed = SkillPromptBuilder.appendAutoFramedContext(
        '--auto {{map.item.spec_path}}',
        inputs: implement.inputs,
        resolvedValues: const {'story_specs': 'STORY LIST'},
        templatePrompt: '--auto {{map.item.spec_path}}',
      );
      expect(framed, isNot(contains('<story_specs>')));
    });

    test('simplify-code declares no story_result input (continued session), so no <story_result> block', () {
      final simplify = def.steps.singleWhere((s) => s.id == 'simplify-code');
      expect(simplify.inputs, isNot(contains('story_result')));
      final framed = SkillPromptBuilder.appendAutoFramedContext(
        '--auto simplify',
        inputs: simplify.inputs,
        resolvedValues: const {'story_result': 'RESULT'},
        templatePrompt: '--auto simplify',
      );
      expect(framed, isNot(contains('<story_result>')));
    });

    test('review-story still frames <story_result>', () {
      final review = def.steps.singleWhere((s) => s.id == 'review-story');
      expect(review.inputs, contains('story_result'));
      final framed = SkillPromptBuilder.appendAutoFramedContext(
        _reviewStoryPrompt,
        inputs: review.inputs,
        resolvedValues: const {'story_result': 'RESULT'},
        templatePrompt: _reviewStoryPrompt,
      );
      expect(framed, contains('<story_result>'));
    });
  });

  group('S05 – code-review re-review reconstructs the original review scope', () {
    final def = _load('code-review.yaml');
    final reReview = def.steps.singleWhere((s) => s.id == 're-review');
    final prompt = reReview.prompts!.join('\n');

    test('interpolates the same target framing as review-code', () {
      for (final ref in const ['{{TARGET}}', '{{BRANCH}}', '{{PR_NUMBER}}', '{{BASE_BRANCH}}']) {
        expect(prompt, contains(ref), reason: ref);
      }
    });

    test('carries no --mode flag (matches review-code)', () {
      expect(prompt, isNot(contains('--mode')));
    });

    test('auto-frames <remediation_summary> as supporting context', () {
      expect(reReview.inputs, contains('remediation_summary'));
      expect(prompt, isNot(contains('{{context.remediation_summary}}')));
      final framed = SkillPromptBuilder.appendAutoFramedContext(
        prompt,
        inputs: reReview.inputs,
        resolvedValues: const {'remediation_summary': 'PRIOR PASS'},
        templatePrompt: prompt,
      );
      expect(framed, contains('<remediation_summary>'));
    });

    test('code-review declares no remediation_result output', () {
      for (final step in def.steps) {
        expect(step.outputs?.containsKey('remediation_result') ?? false, isFalse, reason: step.id);
      }
    });
  });
}

const _reviewStoryPrompt =
    "--mode gap,code,security --auto --output-dir \"x/reviews\" Review a/spec.md on this story's branch.";
