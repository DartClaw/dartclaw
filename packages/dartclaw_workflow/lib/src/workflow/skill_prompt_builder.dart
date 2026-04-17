import 'package:dartclaw_models/dartclaw_models.dart' show OutputConfig, WorkflowStep;

import 'prompt_augmenter.dart';

/// Builds agent prompts for skill-aware workflow steps.
///
/// Handles the 4 prompt construction cases:
/// - skill + prompt: `"Use the '<skill>' skill.\n\n<resolved prompt>"`
/// - skill + no (or empty) prompt: `"Use the '<skill>' skill.\n\n<framed context sections>"`
/// - no skill + prompt: `"<resolved prompt>"` (passthrough)
/// - no skill + no prompt: error (caught by validator, not here)
///
/// After construction, delegates to [PromptAugmenter] for schema-driven
/// output format section appendage (S01 integration).
class SkillPromptBuilder {
  final PromptAugmenter _augmenter;

  const SkillPromptBuilder({required PromptAugmenter augmenter}) : _augmenter = augmenter;

  /// Maximum rendered length for a single context value before truncation.
  ///
  /// Chosen generously (~50K chars ≈ ~12K tokens) since values here are
  /// already bounded by upstream step token budgets. Truncation is a
  /// safety net for pathological inputs, not a default compaction strategy.
  static const int defaultMaxValueLength = 50000;

  /// Builds the effective prompt for a workflow step.
  ///
  /// [skill] is the skill name (null for non-skill steps).
  /// [resolvedPrompt] is the template-resolved prompt. When null **or
  /// empty**, the builder falls back to [contextSummary] (for skill
  /// steps) or to an empty prompt (for non-skill steps — the validator
  /// rejects this combination upstream).
  /// [contextSummary] provides pre-rendered context sections when prompt
  /// is absent — produced by [formatContextSummary].
  /// [outputs] and [contextOutputs] are forwarded to [PromptAugmenter].
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
        // Case 2: skill + no prompt — framed context sections stand alone.
        // Sections carry their own `##` headers, so no literal "Context:"
        // preamble is needed.
        prompt = '$skillLine\n\n$contextSummary';
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

  /// Renders resolved context inputs as markdown sections.
  ///
  /// Each entry becomes a `## <Pretty Name>` block. When an [OutputConfig]
  /// is available for a key (via [outputConfigs]), the description comes
  /// from [PromptAugmenter.effectiveDescription] — inline override first,
  /// then preset fallback — matching the description rendered in the
  /// workflow-output-contract section.
  ///
  /// Values are rendered via `toString()`. Non-string values (Maps, Lists)
  /// produce Dart's debug-format output rather than JSON. Callers that
  /// need JSON rendering should pre-serialize before passing.
  ///
  /// Values exceeding [maxValueLength] are truncated with a visible
  /// marker. Truncation snaps back off any split UTF-16 surrogate pair so
  /// the cut doesn't produce mojibake. Empty or null values render as
  /// `_(empty)_` so the agent sees the contract was honoured but the
  /// producer returned nothing.
  ///
  /// Example output for `{project_index: "...", stories: "..."}`:
  ///
  /// ```
  /// ## Project Index
  ///
  /// Map of document kind → path describing the project layout.
  ///
  /// {project_index value}
  ///
  /// ## Stories
  ///
  /// {stories value}
  /// ```
  static String formatContextSummary(
    Map<String, dynamic> resolvedInputs, {
    Map<String, OutputConfig>? outputConfigs,
    int maxValueLength = defaultMaxValueLength,
  }) {
    if (resolvedInputs.isEmpty) return '';

    final buf = StringBuffer();
    var first = true;
    for (final entry in resolvedInputs.entries) {
      if (!first) {
        buf.writeln();
        buf.writeln();
      }
      first = false;

      buf.writeln('## ${_prettyTitle(entry.key)}');
      buf.writeln();

      final config = outputConfigs?[entry.key];
      final description = config == null ? null : PromptAugmenter.effectiveDescription(config);
      if (description != null && description.isNotEmpty) {
        buf.writeln(description);
        buf.writeln();
      }

      final raw = entry.value?.toString() ?? '';
      if (raw.isEmpty) {
        buf.write('_(empty)_');
      } else if (raw.length > maxValueLength) {
        final cutIndex = _safeTruncateIndex(raw, maxValueLength);
        final dropped = raw.length - cutIndex;
        buf.write(raw.substring(0, cutIndex));
        buf.writeln();
        buf.writeln();
        buf.write('_…[truncated $dropped chars]_');
      } else {
        buf.write(raw);
      }
    }
    return buf.toString();
  }

  /// Builds the `{contextKey → OutputConfig}` map used by
  /// [formatContextSummary] to render description lines.
  ///
  /// Scans [steps] in declaration order and records the first
  /// `OutputConfig` found for each requested [keys] entry. Keys with no
  /// matching producer are omitted (the summary simply skips the
  /// description line for them).
  ///
  /// When multiple steps produce the same key (e.g. `validation_summary`
  /// emitted by both a validate step and a re-validate step), the first
  /// wins. Producers sharing a canonical name are expected to share the
  /// same semantic description.
  static Map<String, OutputConfig> collectInputConfigs(
    Iterable<WorkflowStep> steps,
    Iterable<String> keys,
  ) {
    final wanted = keys.toSet();
    if (wanted.isEmpty) return const {};

    final result = <String, OutputConfig>{};
    for (final step in steps) {
      final outs = step.outputs;
      if (outs == null || outs.isEmpty) continue;
      for (final entry in outs.entries) {
        if (!wanted.contains(entry.key)) continue;
        result.putIfAbsent(entry.key, () => entry.value);
      }
      if (result.length == wanted.length) break;
    }
    return result;
  }

  /// Converts `snake_case` / `kebab-case` keys to `Title Case`. Falls back
  /// to the raw key when the conversion would produce an empty string
  /// (e.g. `'___'`), and to `'(unnamed)'` when the raw key itself is
  /// empty, so we never emit a naked `## ` header.
  static String _prettyTitle(String key) {
    final titled = key
        .split(RegExp(r'[_\-]'))
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
    if (titled.isNotEmpty) return titled;
    return key.isNotEmpty ? key : '(unnamed)';
  }

  /// Returns an index ≤ [limit] that does not split a UTF-16 surrogate
  /// pair. If the code unit at [limit] is a low surrogate (0xDC00–0xDFFF)
  /// and the preceding code unit is a high surrogate (0xD800–0xDBFF), we
  /// snap back by one so the pair stays intact on the "kept" side of the
  /// cut. `String.substring` is code-unit-indexed, so this guards the one
  /// concrete case where truncation would produce mojibake.
  static int _safeTruncateIndex(String raw, int limit) {
    if (limit <= 0 || limit >= raw.length) return limit;
    final cu = raw.codeUnitAt(limit);
    if (cu >= 0xDC00 && cu <= 0xDFFF) {
      final prev = raw.codeUnitAt(limit - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) {
        return limit - 1;
      }
    }
    return limit;
  }
}
