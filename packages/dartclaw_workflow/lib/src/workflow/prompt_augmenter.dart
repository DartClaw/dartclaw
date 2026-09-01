import 'workflow_definition.dart' show OutputConfig, OutputFormat, OutputMode;

import 'review_scoring_fragment.dart';
import 'schema_presets.dart';
import 'schema_prompt_fragment.dart';
import 'workflow_output_contract.dart' show stepOutcomeClose, stepOutcomeOpen;

/// Augments a step prompt with output format instructions from schema declarations.
class PromptAugmenter {
  const new();

  /// Returns [prompt] with appended output-format instructions.
  ///
  /// [finalizerCoveredKeys] names the declared output keys the structured
  /// finalization envelope (see `buildExecutionEnvelopeSchema`) claims: those
  /// keys are excluded from every main-prompt output-contract section (their
  /// instruction moves to the finalizer turn, `buildFinalizerPrompt`). The
  /// remaining declared keys — host-owned `source` keys — still render their
  /// contract here. A non-finalizer step passes an empty set, so all declared
  /// keys render. Callers must supply the step-gated set (empty unless
  /// `stepNeedsFinalizer` is true); the augmenter does not re-derive finalizer
  /// eligibility.
  ///
  /// The `## Step Outcome Protocol` section stays gated by
  /// [emitStepOutcomeProtocol] alone — re-rendering an envelope-excluded output
  /// key never re-enables it.
  String augment(
    String prompt, {
    Map<String, OutputConfig>? outputs,
    List<String> outputKeys = const [],
    bool emitStepOutcomeProtocol = false,
    List<String> finalizerCoveredKeys = const [],
  }) {
    final covered = finalizerCoveredKeys.toSet();
    final renderedOutputs = covered.isEmpty || outputs == null
        ? outputs
        : {
            for (final entry in outputs.entries)
              if (!covered.contains(entry.key)) entry.key: entry.value,
          };
    final renderedKeys = covered.isEmpty
        ? outputKeys
        : [
            for (final key in outputKeys)
              if (!covered.contains(key)) key,
          ];

    final sections = <String>[];

    // Built from the *unfiltered* outputs: a key the finalizer emits is still a
    // key this turn has to decide, and the description is the step's contract
    // with the model. Only the emission protocol belongs to the finalizer.
    final declaredSection = _buildDeclaredOutputsSection(outputs);
    if (declaredSection != null) sections.add(declaredSection);

    final schemaSection = _buildSchemaSection(renderedOutputs, renderedKeys);
    if (schemaSection != null) sections.add(schemaSection);

    final reviewScoringSection = _buildReviewScoringSection(renderedOutputs);
    if (reviewScoringSection != null) sections.add(reviewScoringSection);

    if (emitStepOutcomeProtocol) {
      sections.add(_buildStepOutcomeSection());
    }

    if (sections.isEmpty) return prompt;

    return '$prompt\n\n${sections.join('\n\n')}';
  }

  String _buildStepOutcomeSection() {
    final buf = StringBuffer();
    buf.writeln('## Step Outcome Protocol');
    buf.writeln();
    buf.writeln(
      'End your final response with '
      '`$stepOutcomeOpen{"outcome":"succeeded|failed|needsInput","reason":"..." }$stepOutcomeClose`.',
    );
    buf.writeln('Do not use markdown code fences inside `$stepOutcomeOpen`.');
    buf.writeln('Allowed outcome values are exactly: `succeeded`, `failed`, `needsInput`.');
    buf.writeln('Use `needsInput` when a human decision or missing requirement blocks safe progress.');
    buf.writeln();
    buf.writeln('Example:');
    buf.writeln(stepOutcomeOpen);
    buf.writeln('{"outcome":"succeeded","reason":"completed as requested"}');
    buf.writeln(stepOutcomeClose);
    return buf.toString().trimRight();
  }

  /// Names every output key the step declares, with the description authored
  /// beside it in the workflow YAML.
  ///
  /// Carries no emission instruction and no envelope example: how the values
  /// leave the turn is the finalizer's contract, what they mean is this one's.
  /// Rendering a key here is what tells the model which question it is
  /// answering — without it a classifier step answers from its input alone.
  String? _buildDeclaredOutputsSection(Map<String, OutputConfig>? outputs) {
    if (outputs == null || outputs.isEmpty) return null;

    final lines = <String>[
      for (final entry in outputs.entries)
        if (effectiveDescription(entry.value) case final desc?) '- "${entry.key}" – $desc',
    ];
    if (lines.isEmpty) return null;

    return '## Declared Outputs\n\nThis step must determine:\n${lines.join('\n')}';
  }

  String? _buildSchemaSection(Map<String, OutputConfig>? outputs, List<String> outputKeys) {
    if (outputs == null || outputs.isEmpty) return null;

    final fragments = <String>[];

    for (final entry in outputs.entries) {
      if (outputKeys.contains(entry.key)) continue;
      final config = entry.value;
      if (config.format != OutputFormat.json) continue;
      if (config.outputMode == OutputMode.structured) continue;

      String? fragment;

      if (config.presetName != null) {
        // Preset schema – use explicit promptFragment when set, otherwise
        // derive the fragment from the schema itself (single source of truth
        // via per-property `description` fields).
        final preset = schemaPresets[config.presetName];
        if (preset != null) {
          fragment = preset.promptFragment ?? describeSchemaForPrompt(preset.schema, entry.key);
        }
      } else if (config.inlineSchema != null) {
        // Inline JSON Schema – generate prompt from schema properties.
        fragment = describeSchemaForPrompt(config.inlineSchema!, entry.key);
      }

      // The description is rendered once, by the declared-outputs section; this
      // one carries the format only.
      if (fragment != null) fragments.add('"${entry.key}"\n\n$fragment');
    }

    if (fragments.isEmpty) return null;

    final section = fragments.join('\n\n');
    return '## Required Output Format\n\n$section';
  }

  String? _buildReviewScoringSection(Map<String, OutputConfig>? outputs) {
    if (outputs == null || outputs.isEmpty) return null;
    final declaresReviewScoringOutput = outputs.values.any(
      (config) => config.presetName == 'gating_findings_count' || config.presetName == 'verdict',
    );
    if (!declaresReviewScoringOutput) return null;
    return reviewScoringFragmentFor(defaultGatingSeverity);
  }

  /// Returns the description to render for [config], falling back to the
  /// preset's canonical description when the output declares a known preset
  /// and no inline `description:` override. Returns null when neither source
  /// provides a non-empty value.
  ///
  /// Exposed as a public static so peer renderers (e.g. `SkillPromptBuilder`'s
  /// auto-framed context sections) share a single description-resolution
  /// strategy. Keeping this in one place prevents drift between the
  /// output-contract rendering here and the context-input rendering there.
  static String? effectiveDescription(OutputConfig config) {
    final inline = config.description?.trim();
    if (inline != null && inline.isNotEmpty) return inline;
    final presetName = config.presetName;
    if (presetName == null) return null;
    final presetDesc = schemaPresets[presetName]?.description?.trim();
    if (presetDesc == null || presetDesc.isEmpty) return null;
    return presetDesc;
  }
}
