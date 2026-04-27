import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_models/dartclaw_models.dart' show OutputConfig, WorkflowStep;

import 'prompt_augmenter.dart';

/// Builds agent prompts for skill-aware workflow steps.
///
/// `<activation>` below is the provider-native skill line produced by
/// [HarnessFactory.skillActivationLineFor] (`/skill` for Claude, `$skill`
/// for Codex, `Use the '<skill>' skill.` otherwise). The gating fields
/// referenced below are parameters of [build]:
///
/// - **Case 1** — `skill` set, `resolvedPrompt` non-empty:
///   `"<activation>\n\n<resolved prompt>"`
/// - **Case 1 (via default)** — `skill` set, `resolvedPrompt` empty,
///   `skillDefaultPrompt` non-empty: the skill's `workflow.default_prompt`
///   is promoted to `effectiveResolvedPrompt` so Case 1 applies
/// - **Case 2** — `skill` set, `effectiveResolvedPrompt` still empty
///   (i.e. neither a step prompt nor a skill default is available),
///   `contextSummary` non-empty:
///   `"<activation>\n\n<## Pretty Name summary>"`
/// - **Case 2b** — `skill` set, `effectiveResolvedPrompt` and
///   `contextSummary` both empty: `"<activation>"` alone
/// - **Case 3** — `skill` null, `resolvedPrompt` non-empty:
///   `"<resolved prompt>"` (passthrough)
/// - **Case 4** — `skill` null, `resolvedPrompt` empty: rejected upstream
///   by the validator
///
/// After construction, the builder auto-frames any unreferenced
/// `inputs` / workflow `variables:` via [appendAutoFramedContext]
/// (skipping the `inputs` list itself when Case 2 already rendered
/// them as markdown sections, to avoid double-rendering), then delegates
/// to [PromptAugmenter] for schema-driven output format section appendage
/// (S01 integration).
class SkillPromptBuilder {
  final PromptAugmenter _augmenter;
  final HarnessFactory _harnessFactory;

  /// [harnessFactory] dispatches the skill-activation line via the same
  /// registry that produces live harness instances — so the activation
  /// convention stays owned by each concrete [AgentHarness] subclass. No
  /// per-provider branching lives in this builder.
  const SkillPromptBuilder({required PromptAugmenter augmenter, required HarnessFactory harnessFactory})
    : _augmenter = augmenter,
      _harnessFactory = harnessFactory;

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
  /// empty**, the builder falls back to [skillDefaultPrompt] (injected so
  /// Case 1 applies), then to [contextSummary] (for skill steps), then to
  /// an empty prompt (for non-skill steps — the validator rejects this
  /// combination upstream).
  /// [contextSummary] provides pre-rendered context sections when prompt
  /// is absent — produced by [formatContextSummary].
  /// [skillDefaultPrompt] is the skill's `workflow.default_prompt` from its
  /// SKILL.md frontmatter — used as the base prompt when a skill step omits
  /// its own `prompt:`.
  /// [autoFrameContext], [inputs], [variables], [resolvedInputValues],
  /// and [templatePrompt] drive the auto-framing pass (appends
  /// `<key>\n{value}\n</key>` blocks for context/variable keys that the
  /// author has not already referenced). See [appendAutoFramedContext].
  /// [outputs] and [outputKeys] are forwarded to [PromptAugmenter].
  /// [emitStepOutcomeProtocol] appends the workflow step-outcome contract.
  /// [provider] picks the native skill-activation convention:
  ///   * `codex` → `$skill-name` (matches agentskills.io standard + Codex CLI)
  ///   * `claude` → `/skill-name` (Claude Code slash-command convention)
  ///   * `null` or unknown → the verbose `Use the 'skill-name' skill.` line
  /// Native activation saves at least one agent turn because the harness
  /// loads the SKILL.md contents itself instead of asking the model to
  /// locate and read the file via a tool call.
  String build({
    required String? skill,
    String? resolvedPrompt,
    String? contextSummary,
    Map<String, OutputConfig>? outputs,
    List<String> outputKeys = const [],
    bool emitStepOutcomeProtocol = false,
    String? skillDefaultPrompt,
    bool autoFrameContext = true,
    List<String> inputs = const [],
    List<String> variables = const [],
    Map<String, Object?> resolvedInputValues = const {},
    String? templatePrompt,
    String? provider,
  }) {
    // Step 1: fall back to the skill's frontmatter `default_prompt` when the
    // step declared no prompt of its own. Injecting here keeps Case 1 as the
    // canonical skill+prompt path; Case 2 (context summary) remains as the
    // tertiary fallback for skills that don't carry a default.
    var effectiveResolvedPrompt = resolvedPrompt;
    if (skill != null &&
        (effectiveResolvedPrompt == null || effectiveResolvedPrompt.isEmpty) &&
        skillDefaultPrompt != null &&
        skillDefaultPrompt.isNotEmpty) {
      effectiveResolvedPrompt = skillDefaultPrompt;
    }

    final String prompt;
    var caseUsedSummary = false;

    if (skill != null) {
      final skillLine = _harnessFactory.skillActivationLineFor(provider, skill);
      if (effectiveResolvedPrompt != null && effectiveResolvedPrompt.isNotEmpty) {
        // Case 1: skill + prompt.
        prompt = '$skillLine\n\n$effectiveResolvedPrompt';
      } else if (contextSummary != null && contextSummary.isNotEmpty) {
        // Case 2: skill + no prompt — framed context sections stand alone.
        // Sections carry their own `##` headers, so no literal "Context:"
        // preamble is needed.
        prompt = '$skillLine\n\n$contextSummary';
        caseUsedSummary = true;
      } else {
        // Case 2b: skill + no prompt + no context.
        prompt = skillLine;
      }
    } else {
      // Case 3: no skill + prompt (passthrough).
      // Case 4 (no skill + no prompt) is rejected by validator.
      prompt = effectiveResolvedPrompt ?? '';
    }

    // Step 2: auto-frame any unreferenced inputs/variables so the
    // agent always receives the declared state, even when the authored
    // template body is pure prose.
    //
    // When Case 2 used `contextSummary` as the body, the inputs
    // are already rendered as markdown sections — skip them in
    // auto-framing to avoid double-rendering every value. Workflow
    // `variables:` are still auto-framed because the summary only covers
    // inputs.
    final framed = autoFrameContext
        ? appendAutoFramedContext(
            prompt,
            inputs: caseUsedSummary ? const <String>[] : inputs,
            variables: variables,
            resolvedValues: resolvedInputValues,
            templatePrompt: templatePrompt,
          )
        : prompt;

    // Step 3: append schema-driven output format section via PromptAugmenter.
    return _augmenter.augment(
      framed,
      outputs: outputs,
      outputKeys: outputKeys,
      emitStepOutcomeProtocol: emitStepOutcomeProtocol,
    );
  }

  /// Appends XML-framed `<tagName>value</tagName>` blocks for each context
  /// input and workflow-level variable that is not already referenced in the
  /// prompt body.
  ///
  /// Detection rules (either suppresses auto-injection for the key):
  /// - **Tag detection** — `<tagName` appears anywhere in [prompt]
  ///   (case-sensitive, prefix-only so XML attributes don't defeat it).
  /// - **Reference detection** — `{{context.key}}` / `{{context.tagName}}`
  ///   or `{{KEY}}` / `{{tagName}}` appears in [templatePrompt]
  ///   (pre-substitution form).
  ///
  /// Tag names normalize `.` → `_` so dotted context keys like
  /// `plan-review.findings_count` render as
  /// `<plan-review_findings_count>…</plan-review_findings_count>`.
  ///
  /// Empty/null resolved values render as `_(empty)_` — matching the
  /// convention used by [formatContextSummary] — so the agent sees that
  /// the contract was honoured but the producer returned nothing.
  ///
  /// [inputs] are processed before [variables]; each key is visited
  /// at most once across both lists.
  static String appendAutoFramedContext(
    String prompt, {
    List<String> inputs = const [],
    List<String> variables = const [],
    Map<String, Object?> resolvedValues = const {},
    String? templatePrompt,
  }) {
    if (inputs.isEmpty && variables.isEmpty) return prompt;

    final buf = StringBuffer(prompt);
    final seen = <String>{};

    void maybeAppend(String key, {required bool isContextInput}) {
      if (key.isEmpty) return;
      if (!seen.add(key)) return;

      final tagName = key.replaceAll('.', '_');

      // Detection A: tag already present — require a proper tag boundary
      // (`>`, whitespace, or `/>` for self-closing) so `<prd>` doesn't
      // suppress auto-injection when the prompt mentions `<prdfoo>` or
      // `<prd-review>` elsewhere.
      if (_tagBoundaryRegExp(tagName).hasMatch(prompt)) return;

      // Detection B: template references the value inline. Uses a
      // whitespace-tolerant regex so `{{ context.key }}` (with spaces)
      // matches the same as `{{context.key}}` — matching the template
      // engine's own tolerance. Both the raw key and the tag-normalized
      // form are accepted so authors who pre-normalized the name also
      // suppress auto-injection.
      if (templatePrompt != null) {
        final keys = key == tagName ? <String>[key] : <String>[key, tagName];
        for (final candidate in keys) {
          final pattern = isContextInput ? 'context.$candidate' : candidate;
          if (_templateReferenceRegExp(pattern).hasMatch(templatePrompt)) {
            return;
          }
        }
      }

      final raw = resolvedValues[key]?.toString() ?? '';
      final rendered = raw.isEmpty ? '_(empty)_' : raw;
      buf.write('\n\n<$tagName>\n$rendered\n</$tagName>');
    }

    for (final key in inputs) {
      maybeAppend(key, isContextInput: true);
    }
    for (final key in variables) {
      maybeAppend(key, isContextInput: false);
    }

    return buf.toString();
  }

  /// Regex matching `<tag>`, `<tag ...>`, or `<tag/>` with a proper tag
  /// boundary so prefix collisions (`<prdfoo>` when looking for `<prd>`)
  /// don't accidentally suppress auto-injection. Case-sensitive — matches
  /// the FIS Detection A contract.
  static RegExp _tagBoundaryRegExp(String tagName) => RegExp('<${RegExp.escape(tagName)}(?:[\\s/>])');

  /// Regex matching `{{ name }}` with optional internal whitespace, matching
  /// the workflow template engine's tolerance.
  static RegExp _templateReferenceRegExp(String name) => RegExp('\\{\\{\\s*${RegExp.escape(name)}\\s*\\}\\}');

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
  static Map<String, OutputConfig> collectInputConfigs(Iterable<WorkflowStep> steps, Iterable<String> keys) {
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
