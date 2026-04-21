import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show OutputConfig, OutputFormat, PromptAugmenter, SkillPromptBuilder, WorkflowStep;
import 'package:test/test.dart';

void main() {
  final builder = SkillPromptBuilder(augmenter: const PromptAugmenter(), harnessFactory: HarnessFactory());

  group('SkillPromptBuilder.build', () {
    test('skill + prompt -> skill line + blank line + prompt', () {
      final result = builder.build(skill: 'dartclaw-review-code', resolvedPrompt: 'Review this file.');
      expect(result, "Use the 'dartclaw-review-code' skill.\n\nReview this file.");
    });

    test('skill + no prompt + contextSummary -> skill line + sections', () {
      final summary = SkillPromptBuilder.formatContextSummary({'findings': 'some findings'});
      final result = builder.build(skill: 'dartclaw-review-code', contextSummary: summary);
      expect(result, "Use the 'dartclaw-review-code' skill.\n\n## Findings\n\nsome findings");
    });

    test('skill + no prompt + contextSummary does not emit legacy "Context:" preamble', () {
      // Regression: pre-Level-1 Case 2 rendered "Use the '...' skill.\n\nContext:\n- k: v".
      // The new sections carry their own `##` headers, so the "Context:" line is gone.
      final summary = SkillPromptBuilder.formatContextSummary({'findings': 'some findings'});
      final result = builder.build(skill: 'dartclaw-review-code', contextSummary: summary);
      expect(result, isNot(contains('Context:')));
    });

    test('skill + no prompt + no context -> skill line only', () {
      final result = builder.build(skill: 'dartclaw-review-code');
      expect(result, "Use the 'dartclaw-review-code' skill.");
    });

    test('no skill + prompt -> passthrough', () {
      final result = builder.build(skill: null, resolvedPrompt: 'Do the task.');
      expect(result, 'Do the task.');
    });

    test('no skill + null prompt -> empty string', () {
      final result = builder.build(skill: null);
      expect(result, '');
    });

    test('skill + empty prompt -> context summary used instead', () {
      final summary = SkillPromptBuilder.formatContextSummary({'key': 'val'});
      final result = builder.build(skill: 'my-skill', resolvedPrompt: '', contextSummary: summary);
      expect(result, "Use the 'my-skill' skill.\n\n## Key\n\nval");
    });

    test('Case 2 contextInputs are not auto-framed (avoid duplication)', () {
      // Regression: when the builder renders contextInputs as a markdown
      // `## Pretty Name` summary (Case 2), auto-framing must not ALSO
      // append `<key>…</key>` blocks for the same keys — they are
      // already present as sections.
      final summary = SkillPromptBuilder.formatContextSummary({'plan': 'plan body', 'spec': 'spec body'});
      final result = builder.build(
        skill: 'my-skill',
        contextSummary: summary,
        contextInputs: const ['plan', 'spec'],
        resolvedInputValues: const {'plan': 'plan body', 'spec': 'spec body'},
      );
      expect(result, contains('## Plan\n\nplan body'));
      expect(result, contains('## Spec\n\nspec body'));
      expect(result, isNot(contains('<plan>')));
      expect(result, isNot(contains('<spec>')));
    });

    test('Case 2 still auto-frames workflow variables that are not part of the summary', () {
      // The no-duplication guard targets contextInputs only — workflow
      // `variables:` are orthogonal and must still be auto-framed.
      final summary = SkillPromptBuilder.formatContextSummary({'plan': 'plan body'});
      final result = builder.build(
        skill: 'my-skill',
        contextSummary: summary,
        contextInputs: const ['plan'],
        variables: const ['REQUIREMENTS'],
        resolvedInputValues: const {'plan': 'plan body', 'REQUIREMENTS': 'req body'},
      );
      expect(result, contains('## Plan\n\nplan body'));
      expect(result, isNot(contains('<plan>')));
      expect(result, contains('<REQUIREMENTS>\nreq body\n</REQUIREMENTS>'));
    });

    test('skill + prompt + schema -> skill line + prompt + Required Output Format', () {
      final result = builder.build(
        skill: 'dartclaw-review-code',
        resolvedPrompt: 'Review this.',
        outputs: {'result': const OutputConfig(format: OutputFormat.json, schema: 'verdict')},
      );
      expect(result, contains("Use the 'dartclaw-review-code' skill."));
      expect(result, contains('Review this.'));
      expect(result, contains('## Required Output Format'));
    });

    test('context outputs append workflow-context contract', () {
      final result = builder.build(
        skill: 'dartclaw-review-code',
        resolvedPrompt: 'Review this.',
        outputs: {'review_summary': const OutputConfig(format: OutputFormat.json, schema: 'verdict')},
        contextOutputs: const ['review_summary', 'findings_count'],
      );
      expect(result, contains('## Workflow Output Contract'));
      expect(result, contains('<workflow-context>'));
      expect(result, contains('"review_summary"'));
      expect(result, contains('"findings_count"'));
      expect(result, isNot(contains('Output the JSON directly')));
    });

    test('no skill + prompt + schema -> prompt + Required Output Format', () {
      final result = builder.build(
        skill: null,
        resolvedPrompt: 'Analyze this.',
        outputs: {'result': const OutputConfig(format: OutputFormat.json, schema: 'verdict')},
      );
      expect(result, startsWith('Analyze this.'));
      expect(result, contains('## Required Output Format'));
    });

    test('skill + no prompt + skillDefaultPrompt -> skill line + default prompt', () {
      final result = builder.build(
        skill: 'dartclaw-quick-review',
        skillDefaultPrompt: 'Quick-review the recent change set.',
      );
      expect(result, "Use the 'dartclaw-quick-review' skill.\n\nQuick-review the recent change set.");
    });

    test('skill + explicit prompt overrides skillDefaultPrompt', () {
      final result = builder.build(
        skill: 'dartclaw-quick-review',
        resolvedPrompt: 'Custom prompt.',
        skillDefaultPrompt: 'Default prompt that should NOT appear.',
      );
      expect(result, contains('Custom prompt.'));
      expect(result, isNot(contains('Default prompt that should NOT appear.')));
    });
  });

  group('SkillPromptBuilder.appendAutoFramedContext', () {
    test('appends XML-framed blocks for each context input when absent', () {
      final result = SkillPromptBuilder.appendAutoFramedContext(
        'Do X',
        contextInputs: const ['project_index', 'prd'],
        resolvedValues: const {'project_index': 'A', 'prd': 'B'},
      );
      expect(result, 'Do X\n\n<project_index>\nA\n</project_index>\n\n<prd>\nB\n</prd>');
    });

    test('skips keys that the prompt already contains as literal tags', () {
      final result = SkillPromptBuilder.appendAutoFramedContext(
        '<prd>inline</prd> Do X',
        contextInputs: const ['project_index', 'prd'],
        resolvedValues: const {'project_index': 'A', 'prd': 'B'},
      );
      expect(result.contains('<project_index>\nA\n</project_index>'), isTrue);
      expect(result.contains('<prd>\nB\n</prd>'), isFalse);
    });

    test('skips keys the template references via {{context.key}}', () {
      final result = SkillPromptBuilder.appendAutoFramedContext(
        'Build using A',
        contextInputs: const ['project_index', 'prd'],
        resolvedValues: const {'project_index': 'A', 'prd': 'B'},
        templatePrompt: 'Build using {{ context.prd }}',
      );
      expect(result.contains('<project_index>\nA\n</project_index>'), isTrue);
      expect(result.contains('<prd>\n'), isFalse);
    });

    test('dotted keys normalize dots to underscores in the tag name', () {
      final result = SkillPromptBuilder.appendAutoFramedContext(
        'Do X',
        contextInputs: const ['plan-review.findings_count'],
        resolvedValues: const {'plan-review.findings_count': '7'},
      );
      expect(result, contains('<plan-review_findings_count>\n7\n</plan-review_findings_count>'));
    });

    test('tag-boundary detection: prefix-only match does NOT suppress', () {
      // Regression for the too-loose detection: a `<prdfoo>` substring
      // must not suppress auto-injection when the key is `prd`.
      final result = SkillPromptBuilder.appendAutoFramedContext(
        '<prdfoo>unrelated</prdfoo>',
        contextInputs: const ['prd'],
        resolvedValues: const {'prd': 'B'},
      );
      expect(result, contains('<prd>\nB\n</prd>'));
    });

    test('tag-boundary detection: tag with attribute DOES suppress', () {
      final result = SkillPromptBuilder.appendAutoFramedContext(
        '<prd lang="en">inline</prd>',
        contextInputs: const ['prd'],
        resolvedValues: const {'prd': 'B'},
      );
      expect(result, isNot(contains('<prd>\nB\n</prd>')));
    });

    test('empty resolved value renders as _(empty)_', () {
      final result = SkillPromptBuilder.appendAutoFramedContext(
        'Do X',
        contextInputs: const ['prd'],
        resolvedValues: const {'prd': ''},
      );
      expect(result, contains('<prd>\n_(empty)_\n</prd>'));
    });

    test('workflow variables auto-frame when a bound value is provided', () {
      final result = SkillPromptBuilder.appendAutoFramedContext(
        'Do X',
        variables: const ['REQUIREMENTS'],
        resolvedValues: const {'REQUIREMENTS': 'Build dashboard'},
      );
      expect(result, contains('<REQUIREMENTS>\nBuild dashboard\n</REQUIREMENTS>'));
    });
  });

  group('SkillPromptBuilder.formatContextSummary', () {
    test('empty map returns empty string', () {
      expect(SkillPromptBuilder.formatContextSummary({}), '');
    });

    test('single entry renders as titled section with value', () {
      final result = SkillPromptBuilder.formatContextSummary({'project_index': 'abc'});
      expect(result, '## Project Index\n\nabc');
    });

    test('snake_case key rendered as Title Case header', () {
      final result = SkillPromptBuilder.formatContextSummary({'validation_summary': 'ok'});
      expect(result, startsWith('## Validation Summary\n'));
    });

    test('kebab-case key rendered as Title Case header', () {
      final result = SkillPromptBuilder.formatContextSummary({'story-result': 'ok'});
      expect(result, startsWith('## Story Result\n'));
    });

    test('single-character key rendered as uppercase header', () {
      final result = SkillPromptBuilder.formatContextSummary({'a': 'ok'});
      expect(result, startsWith('## A\n'));
    });

    test('already-titled key passes through intact', () {
      final result = SkillPromptBuilder.formatContextSummary({'Project': 'ok'});
      expect(result, startsWith('## Project\n'));
    });

    test('mixed separators (_ and -) both split', () {
      final result = SkillPromptBuilder.formatContextSummary({'foo_bar-baz': 'ok'});
      expect(result, startsWith('## Foo Bar Baz\n'));
    });

    test('consecutive separators collapse', () {
      final result = SkillPromptBuilder.formatContextSummary({'foo__bar': 'ok'});
      expect(result, startsWith('## Foo Bar\n'));
    });

    test('leading and trailing separators are ignored', () {
      final result = SkillPromptBuilder.formatContextSummary({'_foo_': 'ok'});
      expect(result, startsWith('## Foo\n'));
    });

    test('empty key falls back to placeholder (no naked "## " header)', () {
      // Pathological input — an empty key should never appear in real
      // YAML, but the helper must not emit a naked `## ` header.
      final result = SkillPromptBuilder.formatContextSummary({'': 'ok'});
      expect(result, startsWith('## (unnamed)\n'));
      expect(result, isNot(startsWith('## \n')));
    });

    test('all-separators key falls back to raw', () {
      final result = SkillPromptBuilder.formatContextSummary({'___': 'ok'});
      expect(result, startsWith('## ___\n'));
    });

    test('multiple entries separated by blank line', () {
      final result = SkillPromptBuilder.formatContextSummary({'a': '1', 'b': '2'});
      expect(result, '## A\n\n1\n\n## B\n\n2');
    });

    test('description from outputConfigs rendered between header and value', () {
      final result = SkillPromptBuilder.formatContextSummary(
        {'story_plan': 'stories-here'},
        outputConfigs: {
          'story_plan': const OutputConfig(
            format: OutputFormat.json,
            description: 'Ordered list of implementation stories.',
          ),
        },
      );
      expect(result, contains('## Story Plan'));
      expect(result, contains('Ordered list of implementation stories.'));
      expect(result, endsWith('stories-here'));
    });

    test('preset description used when inline description is null', () {
      // Regression for Finding 3: formatContextSummary must share
      // PromptAugmenter's effectiveDescription strategy so preset-declared
      // fields like `schema: validation-summary` produce the same
      // description across auto-framed context sections and the workflow
      // output contract.
      final result = SkillPromptBuilder.formatContextSummary(
        {'validation_summary': 'ok'},
        outputConfigs: {
          'validation_summary': const OutputConfig(format: OutputFormat.text, schema: 'validation-summary'),
        },
      );
      expect(result, contains('## Validation Summary'));
      expect(result, contains('Summary of validation outcomes'));
    });

    test('inline description overrides preset description', () {
      final result = SkillPromptBuilder.formatContextSummary(
        {'story_result': 'r'},
        outputConfigs: {
          'story_result': const OutputConfig(
            format: OutputFormat.text,
            schema: 'story-result',
            description: 'Custom override.',
          ),
        },
      );
      expect(result, contains('Custom override.'));
      expect(result, isNot(contains('Summary of what was implemented')));
    });

    test('missing outputConfig entry -> no description line', () {
      final result = SkillPromptBuilder.formatContextSummary(
        {'plain_key': 'val'},
        outputConfigs: const {},
      );
      expect(result, '## Plain Key\n\nval');
    });

    test('outputConfig without description or preset -> no description line', () {
      final result = SkillPromptBuilder.formatContextSummary(
        {'plain_key': 'val'},
        outputConfigs: {'plain_key': const OutputConfig(format: OutputFormat.text)},
      );
      expect(result, '## Plain Key\n\nval');
    });

    test('whitespace-only inline description falls back to preset description', () {
      final result = SkillPromptBuilder.formatContextSummary(
        {'story_result': 'r'},
        outputConfigs: {
          'story_result': const OutputConfig(
            format: OutputFormat.text,
            schema: 'story-result',
            description: '   ',
          ),
        },
      );
      expect(result, contains('Summary of what was implemented'));
    });

    test('non-string Map value renders via Dart toString (debug format)', () {
      // Documents (does not endorse) current behaviour: WorkflowContext
      // stores `dynamic` values; formatContextSummary renders with
      // `toString()`. Callers that need JSON should pre-serialize.
      final result = SkillPromptBuilder.formatContextSummary({
        'payload': {'a': 1, 'b': 2},
      });
      expect(result, contains('## Payload'));
      // Dart's Map.toString produces `{a: 1, b: 2}`, not JSON.
      expect(result, contains('{a: 1, b: 2}'));
    });

    test('non-string List value renders via Dart toString', () {
      final result = SkillPromptBuilder.formatContextSummary({
        'items': [1, 2, 3],
      });
      expect(result, contains('## Items'));
      expect(result, contains('[1, 2, 3]'));
    });

    test('value exceeding maxValueLength is truncated with visible marker', () {
      final longValue = 'x' * 1200;
      final result = SkillPromptBuilder.formatContextSummary(
        {'big': longValue},
        maxValueLength: 1000,
      );
      expect(result, contains('x' * 1000));
      expect(result, contains('_…[truncated 200 chars]_'));
      expect(result, isNot(contains('x' * 1001)));
    });

    test('truncation does not split a UTF-16 surrogate pair', () {
      // "🎉" is U+1F389 — encoded as surrogate pair (2 code units) in UTF-16.
      // With maxValueLength=2 on "a🎉b" (code-unit length 4), naive
      // substring(0, 2) cuts between the high and low surrogate, producing
      // mojibake. _safeTruncateIndex snaps back to index 1 (keeps "a").
      final raw = 'a🎉b';
      expect(raw.length, 4); // 1 + 2 (surrogate pair) + 1 in code units.
      final result = SkillPromptBuilder.formatContextSummary(
        {'key': raw},
        maxValueLength: 2,
      );
      final kept = result.substring('## Key\n\n'.length, result.indexOf('\n\n_…'));
      expect(kept, 'a');
      expect(result, contains('_…[truncated 3 chars]_'));
    });

    test('truncation preserves an intact surrogate pair at the cut', () {
      // Same string, maxValueLength=3: substring(0, 3) ends cleanly after
      // the low surrogate ("a🎉"), so no snap-back happens.
      final raw = 'a🎉b';
      final result = SkillPromptBuilder.formatContextSummary(
        {'key': raw},
        maxValueLength: 3,
      );
      final kept = result.substring('## Key\n\n'.length, result.indexOf('\n\n_…'));
      expect(kept, 'a🎉');
      expect(result, contains('_…[truncated 1 chars]_'));
    });

    test('null value renders as empty marker', () {
      final result = SkillPromptBuilder.formatContextSummary({'key': null});
      expect(result, '## Key\n\n_(empty)_');
    });

    test('empty string value renders as empty marker', () {
      final result = SkillPromptBuilder.formatContextSummary({'key': ''});
      expect(result, '## Key\n\n_(empty)_');
    });
  });

  group('SkillPromptBuilder.collectInputConfigs', () {
    test('returns empty map when keys is empty', () {
      expect(SkillPromptBuilder.collectInputConfigs(const [], const []), isEmpty);
    });

    test('returns empty map when no step produces any wanted key', () {
      const step = WorkflowStep(id: 'a', name: 'A', type: 'analysis');
      expect(SkillPromptBuilder.collectInputConfigs([step], ['missing']), isEmpty);
    });

    test('first producer wins when multiple steps produce same key', () {
      const first = WorkflowStep(
        id: 'a',
        name: 'A',
        type: 'analysis',
        outputs: {
          'summary': OutputConfig(format: OutputFormat.text, description: 'From A'),
        },
      );
      const second = WorkflowStep(
        id: 'b',
        name: 'B',
        type: 'analysis',
        outputs: {
          'summary': OutputConfig(format: OutputFormat.text, description: 'From B'),
        },
      );
      final result = SkillPromptBuilder.collectInputConfigs([first, second], ['summary']);
      expect(result['summary']?.description, 'From A');
    });

    test('keys with no producer are absent from result', () {
      const step = WorkflowStep(
        id: 'a',
        name: 'A',
        type: 'analysis',
        outputs: {'known': OutputConfig(format: OutputFormat.text)},
      );
      final result = SkillPromptBuilder.collectInputConfigs([step], ['known', 'missing']);
      expect(result.keys, ['known']);
    });

    test('stops scanning once all wanted keys are found', () {
      const first = WorkflowStep(
        id: 'a',
        name: 'A',
        type: 'analysis',
        outputs: {
          'alpha': OutputConfig(format: OutputFormat.text, description: 'A-alpha'),
          'beta': OutputConfig(format: OutputFormat.text, description: 'A-beta'),
        },
      );
      // Second step also has alpha — but first step already provided everything
      // we wanted, so second step's override should never run (first-wins
      // semantic is what matters here, but this documents early-exit intent).
      const second = WorkflowStep(
        id: 'b',
        name: 'B',
        type: 'analysis',
        outputs: {
          'alpha': OutputConfig(format: OutputFormat.text, description: 'B-alpha'),
        },
      );
      final result = SkillPromptBuilder.collectInputConfigs([first, second], ['alpha', 'beta']);
      expect(result['alpha']?.description, 'A-alpha');
      expect(result['beta']?.description, 'A-beta');
    });
  });
}
