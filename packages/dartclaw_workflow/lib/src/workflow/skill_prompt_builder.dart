import 'package:dartclaw_models/dartclaw_models.dart' show OutputConfig;

import 'prompt_augmenter.dart';

/// Builds agent prompts for skill-aware workflow steps.
///
/// Handles the 4 prompt construction cases:
/// - skill + prompt: `"Use the '<skill>' skill.\n\n<resolved prompt>"`
/// - skill + no prompt: `"Use the '<skill>' skill.\n\nContext:\n- key: value..."`
/// - no skill + prompt: `"<resolved prompt>"` (passthrough)
/// - no skill + no prompt: error (caught by validator, not here)
///
/// After construction, delegates to [PromptAugmenter] for schema-driven
/// output format section appendage (S01 integration).
class SkillPromptBuilder {
  final PromptAugmenter _augmenter;

  const SkillPromptBuilder({required PromptAugmenter augmenter}) : _augmenter = augmenter;

  /// Builds the effective prompt for a workflow step.
  ///
  /// [skill] is the skill name (null for non-skill steps).
  /// [resolvedPrompt] is the template-resolved prompt (may be null for
  /// skill-only steps). [contextSummary] provides context when prompt is
  /// absent — formatted as `"- key: <value>"` lines from resolved
  /// contextInputs. [outputs] and [contextOutputs] are forwarded to
  /// [PromptAugmenter] for schema and workflow-context augmentation.
  String build({
    required String? skill,
    String? resolvedPrompt,
    String? contextSummary,
    Map<String, OutputConfig>? outputs,
    List<String> contextOutputs = const [],
  }) {
    final String prompt;

    if (skill != null) {
      final skillLine = "Use the '$skill' skill.";
      if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
        // Case 1: skill + prompt.
        prompt = '$skillLine\n\n$resolvedPrompt';
      } else if (contextSummary != null && contextSummary.isNotEmpty) {
        // Case 2: skill + no prompt, context from contextInputs.
        prompt = '$skillLine\n\nContext:\n$contextSummary';
      } else {
        // Case 2b: skill + no prompt + no context.
        prompt = skillLine;
      }
    } else {
      // Case 3: no skill + prompt (passthrough).
      // Case 4 (no skill + no prompt) is rejected by validator.
      prompt = resolvedPrompt ?? '';
    }

    // Append schema-driven output format section via PromptAugmenter (S01).
    return _augmenter.augment(prompt, outputs: outputs, contextOutputs: contextOutputs);
  }

  /// Formats resolved context inputs as a summary string for skill-only steps.
  ///
  /// Each key-value pair rendered as `"- key: <value>"` (value truncated
  /// at 2000 chars for prompt economy).
  static String formatContextSummary(Map<String, dynamic> resolvedInputs) {
    if (resolvedInputs.isEmpty) return '';
    final buf = StringBuffer();
    for (final entry in resolvedInputs.entries) {
      final value = entry.value?.toString() ?? '';
      final display = value.length > 2000 ? '${value.substring(0, 2000)}...' : value;
      buf.writeln('- ${entry.key}: $display');
    }
    return buf.toString().trimRight();
  }
}
