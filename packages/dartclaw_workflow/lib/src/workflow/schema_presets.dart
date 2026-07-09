import 'workflow_definition.dart' show OutputConfig, OutputFormat;

import 'output_resolver.dart';
import 'story_specs_schema.dart';

/// A built-in schema preset with JSON Schema and prompt fragment.
class SchemaPreset {
  /// Preset name (used in YAML: `schema: verdict`).
  final String name;

  /// Output format this preset expects when referenced as output shorthand.
  final OutputFormat format;

  /// JSON Schema definition. Per-property `description` fields drive prompt
  /// generation for JSON presets – see `PromptAugmenter._writeProperties`.
  final Map<String, dynamic> schema;

  /// Optional override prompt fragment for JSON outputs. When null, the
  /// augmenter derives the fragment from [schema] itself (property types +
  /// JSON Schema `description` fields), which keeps the shape definition in
  /// one place. Null for `format: text` presets (no schema section rendered).
  final String? promptFragment;

  /// Optional canonical one-line description for this output. Used when a
  /// workflow references the preset without overriding `description:` on
  /// the output config, so common semantic fields stay consistent across
  /// workflows.
  final String? description;

  /// Default resolver used when [fieldResolvers] does not name a field.
  final OutputResolver? defaultResolver;

  /// Field-specific resolver declarations for canonical output keys.
  final Map<String, OutputResolver> fieldResolvers;

  const SchemaPreset({
    required this.name,
    required this.format,
    required this.schema,
    this.promptFragment,
    this.description,
    this.defaultResolver,
    this.fieldResolvers = const <String, OutputResolver>{},
  });

  /// Returns the resolver declared for [fieldName].
  OutputResolver? resolverFor(String fieldName) {
    final explicit = fieldResolvers[fieldName];
    if (explicit != null) return _withSchemaKey(explicit, fieldName);
    final fallback = defaultResolver;
    return fallback == null ? null : _withSchemaKey(fallback, fieldName);
  }
}

/// Resolves the output source policy for [outputKey].
OutputResolver outputResolverFor(String outputKey, OutputConfig? config) {
  final override = config?.resolverOverride;
  if (override != null) return _withSchemaKey(override, outputKey);
  final presetName = config?.presetName;
  if (presetName != null) {
    final resolver = schemaPresets[presetName]?.resolverFor(outputKey);
    if (resolver != null) return resolver;
  }
  return defaultOutputResolverFor(outputKey, config);
}

/// Resolver for an output that declares no `resolver:`/`pathPattern`/preset.
///
/// Name-agnostic: a `format: path` output falls back to the uniform `**/*`
/// glob, a path-list to the same in list mode, and everything else to inline.
/// Key-specific resolution comes only from an explicit declaration or a preset
/// – never from the output key's name.
OutputResolver defaultOutputResolverFor(String outputKey, OutputConfig? config) {
  if (config?.format == OutputFormat.path) {
    return const FileSystemOutput(pathPattern: '**/*', listMode: false);
  }
  if (config?.format == OutputFormat.lines && _looksLikePathList(outputKey)) {
    return const FileSystemOutput(pathPattern: '**/*', listMode: true);
  }
  return InlineOutput(schemaKey: outputKey);
}

const _pathListOutputSuffix = '_paths';

bool _looksLikePathList(String outputKey) => outputKey.endsWith(_pathListOutputSuffix);

OutputResolver _withSchemaKey(OutputResolver resolver, String fieldName) {
  return switch (resolver) {
    FileSystemOutput(:final pathPattern, :final listMode, :final preferPatterns) => FileSystemOutput(
      pathPattern: pathPattern,
      listMode: listMode,
      preferPatterns: preferPatterns,
    ),
    InlineOutput() => InlineOutput(schemaKey: fieldName),
  };
}

/// Built-in schema presets registry.
final schemaPresets = _validatedSchemaPresets({
  'verdict': verdictPreset,
  'story_specs': storySpecsPreset,
  'non_negative_integer': nonNegativeIntegerPreset,
  'narrative_text': narrativeTextPreset,
  'diff_summary': diffSummaryPreset,
  'validation_summary': validationSummaryPreset,
  'gating_findings_count': gatingFindingsCountPreset,
  'findings_count': findingsCountPreset,
  'review_report_path': reviewReportPathPreset,
});

/// Whether [presetName] identifies a review-report path preset.
///
bool isReviewReportPathPreset(String? presetName) => presetName == 'review_report_path';

Map<String, SchemaPreset> _validatedSchemaPresets(Map<String, SchemaPreset> presets) {
  for (final entry in presets.entries) {
    if (entry.value.name != entry.key) {
      throw StateError('Schema preset key "${entry.key}" does not match preset name "${entry.value.name}".');
    }
    if (OutputFormat.fromYaml(entry.key) != null) {
      throw StateError('Schema preset "${entry.key}" must not shadow an output format shorthand keyword.');
    }
  }
  return Map.unmodifiable(presets);
}

const verdictPreset = SchemaPreset(
  name: 'verdict',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'verdict'),
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['pass', 'findings_count', 'findings', 'summary'],
    'properties': {
      'pass': {'type': 'boolean', 'description': 'Whether the review passes overall.'},
      'findings_count': {'type': 'integer', 'description': 'Total number of findings in `findings`.'},
      'findings': {
        'type': 'array',
        'description': 'Structured list of issues. Empty when `pass` is true.',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['severity', 'location', 'description'],
          'properties': {
            'severity': {
              'type': 'string',
              'enum': ['critical', 'high', 'medium', 'low'],
              'description': 'Severity tier.',
            },
            'location': {'type': 'string', 'description': 'File path and line reference.'},
            'description': {'type': 'string', 'description': 'What the issue is and why it matters.'},
          },
        },
      },
      'summary': {'type': 'string', 'description': '2-3 sentence overall assessment.'},
    },
  },
);

const storySpecsPreset = SchemaPreset(
  name: 'story_specs',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'story_specs'),
  fieldResolvers: {'story_specs': InlineOutput(schemaKey: 'story_specs')},
  schema: storySpecsSchema,
  description:
      'Per-story records driving the foreach controller; populated from an existing plan or by the plan step for a synthesized plan.',
);

const _nonNegativeIntegerPromptFragment = 'Produce a non-negative integer (0 or greater). Output the number directly.';

/// Simple scalar schema for non-negative integer counters like `findings_count`.
const nonNegativeIntegerPreset = SchemaPreset(
  name: 'non_negative_integer',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'count'),
  schema: {'type': 'integer', 'minimum': 0},
  promptFragment: _nonNegativeIntegerPromptFragment,
);

/// Generic free-text output. Carries **no description** – framework
/// semantics live in each call site's inline `description:` (per package
/// convention: only generic presets belong in the engine registry).
const narrativeTextPreset = SchemaPreset(
  name: 'narrative_text',
  format: OutputFormat.text,
  defaultResolver: InlineOutput(schemaKey: 'narrative_text'),
  schema: {'type': 'string'},
);

/// Canonical text shape for `diff_summary` outputs across implementation,
/// remediation, and validation steps.
const diffSummaryPreset = SchemaPreset(
  name: 'diff_summary',
  format: OutputFormat.text,
  defaultResolver: InlineOutput(schemaKey: 'diff_summary'),
  schema: {'type': 'string'},
  description: 'Compact description of file-level changes produced by this step (files touched, nature of edits).',
);

/// Canonical text shape for `validation_summary` outputs emitted by verify /
/// re-validate steps.
const validationSummaryPreset = SchemaPreset(
  name: 'validation_summary',
  format: OutputFormat.text,
  defaultResolver: InlineOutput(schemaKey: 'validation_summary'),
  schema: {'type': 'string'},
  description: 'Summary of validation outcomes for this step (build, tests, analyzer, and any refinements applied).',
);

const _gatingFindingsCountDescription =
    'Non-negative count of findings at or above the resolved gating-severity threshold. The remediation loop reads this field to decide whether to iterate; 0 means no finding of gating severity remains.';

const gatingFindingsCountPreset = SchemaPreset(
  name: 'gating_findings_count',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'count'),
  schema: {'type': 'integer', 'minimum': 0},
  description: _gatingFindingsCountDescription,
  promptFragment: _nonNegativeIntegerPromptFragment,
);

const findingsCountPreset = SchemaPreset(
  name: 'findings_count',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'count'),
  schema: {'type': 'integer', 'minimum': 0},
  description: 'Number of issues flagged by this review; 0 means clean.',
  promptFragment: _nonNegativeIntegerPromptFragment,
);

const reviewReportPathPreset = SchemaPreset(
  name: 'review_report_path',
  format: OutputFormat.path,
  schema: {'type': 'string'},
  description:
      'Path to the review report file written by the invoking review skill. The form is dictated by the skill contract: absolute when the skill writes via --output-dir outside the project root; otherwise project-root-relative. Aggregate-reviews joins relative values under the active workspace root.',
);
