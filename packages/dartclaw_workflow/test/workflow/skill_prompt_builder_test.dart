import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show OutputConfig, OutputFormat, PromptAugmenter, SkillPromptBuilder;
import 'package:test/test.dart';

void main() {
  final builder = SkillPromptBuilder(augmenter: const PromptAugmenter());

  group('SkillPromptBuilder.build', () {
    test('skill + prompt -> skill line + blank line + prompt', () {
      final result = builder.build(skill: 'dartclaw-review-code', resolvedPrompt: 'Review this file.');
      expect(result, "Use the 'dartclaw-review-code' skill.\n\nReview this file.");
    });

    test('skill + no prompt + contextSummary -> skill line + Context section', () {
      final result = builder.build(skill: 'dartclaw-review-code', contextSummary: '- findings: some findings');
      expect(result, "Use the 'dartclaw-review-code' skill.\n\nContext:\n- findings: some findings");
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
      final result = builder.build(skill: 'my-skill', resolvedPrompt: '', contextSummary: '- key: val');
      expect(result, "Use the 'my-skill' skill.\n\nContext:\n- key: val");
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
  });

  group('SkillPromptBuilder.formatContextSummary', () {
    test('empty map returns empty string', () {
      expect(SkillPromptBuilder.formatContextSummary({}), '');
    });

    test('single entry renders as bullet line', () {
      final result = SkillPromptBuilder.formatContextSummary({'key': 'value'});
      expect(result, '- key: value');
    });

    test('multiple entries render as bullet lines', () {
      final result = SkillPromptBuilder.formatContextSummary({'a': '1', 'b': '2'});
      expect(result, contains('- a: 1'));
      expect(result, contains('- b: 2'));
    });

    test('value exceeding 2000 chars is truncated with ellipsis', () {
      final longValue = 'x' * 2500;
      final result = SkillPromptBuilder.formatContextSummary({'big': longValue});
      expect(result, contains('- big: ${'x' * 2000}...'));
      expect(result.length, lessThan(2100)); // not the full 2500
    });

    test('null value renders as empty string', () {
      final result = SkillPromptBuilder.formatContextSummary({'key': null});
      // null is rendered as empty; trailing space trimmed by trimRight().
      expect(result, '- key:');
    });
  });
}
