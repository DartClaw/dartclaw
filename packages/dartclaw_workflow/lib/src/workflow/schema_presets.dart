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
  final presetName = config?.presetName;
  if (presetName != null) {
    final resolver = schemaPresets[presetName]?.resolverFor(outputKey);
    if (resolver != null) return resolver;
  }
  return defaultOutputResolverFor(outputKey, config);
}

/// Infers a backward-compatible resolver for workflows without declarations.
OutputResolver defaultOutputResolverFor(String outputKey, OutputConfig? config) {
  if (config?.format == OutputFormat.path) {
    return FileSystemOutput(pathPattern: _defaultPathPattern(outputKey), listMode: false);
  }
  if (config?.format == OutputFormat.lines && _looksLikePathList(outputKey)) {
    return FileSystemOutput(pathPattern: _defaultPathPattern(outputKey), listMode: true);
  }
  if (_narrativeOutputKeys.contains(outputKey)) {
    return NarrativeOutput(schemaKey: outputKey);
  }
  return InlineOutput(schemaKey: outputKey);
}

OutputResolver _withSchemaKey(OutputResolver resolver, String fieldName) {
  return switch (resolver) {
    FileSystemOutput(:final pathPattern, :final listMode) => FileSystemOutput(
      pathPattern: pathPattern,
      listMode: listMode,
    ),
    InlineOutput() => InlineOutput(schemaKey: fieldName),
    NarrativeOutput() => NarrativeOutput(schemaKey: fieldName),
  };
}

String _defaultPathPattern(String outputKey) {
  return switch (outputKey) {
    'prd' || 'prd_path' => '**/*prd.md',
    'plan' || 'plan_path' => '**/*plan.{json,md}',
    'technical_research' || 'technical_research_path' => '**/.technical-research.md',
    'fis_paths' || 'story_spec_paths' => 'fis/s*.md',
    'spec_path' || 'story_spec' || 'story_spec_path' => '**/*.md',
    'review_findings' => '**/*review*.md',
    'architecture_review_findings' => '**/*architecture*.md',
    _ => '**/*',
  };
}

bool _looksLikePathList(String outputKey) {
  return outputKey == 'fis_paths' || outputKey == 'story_spec_paths' || outputKey.endsWith('_paths');
}

const _narrativeOutputKeys = <String>{
  'confidence',
  'diff_summary',
  'findings_summary',
  'plan_source',
  'prd_source',
  'remediation_summary',
  'spec_confidence',
  'spec_source',
  'state_update_summary',
  'summary',
  'technical_research',
  'validation_summary',
};

/// Built-in schema presets registry.
final schemaPresets = _validatedSchemaPresets({
  'verdict': verdictPreset,
  'remediation_result': remediationResultPreset,
  'story_plan': storyPlanPreset,
  'story_specs': storySpecsPreset,
  'file_list': fileListPreset,
  'checklist': checklistPreset,
  'non_negative_integer': nonNegativeIntegerPreset,
  'diff_summary': diffSummaryPreset,
  'validation_summary': validationSummaryPreset,
  'state_update_summary': stateUpdateSummaryPreset,
  'remediation_summary': remediationSummaryPreset,
  'story_result': storyResultPreset,
  'gating_findings_count': gatingFindingsCountPreset,
  'findings_count': findingsCountPreset,
  'review_report_path': reviewReportPathPreset,
  'prd_path': prdPathPreset,
  'plan_path': planPathPreset,
  'fis_path': fisPathPreset,
  'detected_fis_path': detectedFisPathPreset,
  'spec_source': specSourcePreset,
  'spec_confidence': specConfidencePreset,
});

/// Whether [presetName] identifies a review-report path preset.
///
/// Recognizes the canonical `review_report_path` plus any future vendor-prefixed
/// variant ending in `_review_report_path` (reserved for review-report shapes
/// that genuinely diverge in schema or semantics – not just producer label).
/// The aggregate-reviews validator and runner share this predicate so both
/// agree on what counts as a per-source review report output.
bool isReviewReportPathPreset(String? presetName) =>
    presetName == 'review_report_path' || (presetName?.endsWith('_review_report_path') ?? false);

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
  defaultResolver: NarrativeOutput(schemaKey: 'verdict'),
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

const storyPlanPreset = SchemaPreset(
  name: 'story_plan',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'stories'),
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['items'],
    'properties': {
      'items': {
        'type': 'array',
        'description': 'Ordered list of stories parsed from the plan.',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['id', 'title', 'description'],
          'properties': {
            'id': {'type': 'string', 'description': 'Short unique identifier (e.g. "s01").'},
            'title': {'type': 'string', 'description': 'Concise story title.'},
            'description': {'type': 'string', 'description': 'One-sentence summary of what this story delivers.'},
          },
        },
      },
    },
  },
);

const remediationResultPreset = SchemaPreset(
  name: 'remediation_result',
  format: OutputFormat.json,
  defaultResolver: NarrativeOutput(schemaKey: 'remediation_result'),
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['remediation_summary', 'diff_summary'],
    'properties': {
      'remediation_summary': {'type': 'string', 'description': 'What was re-validated and changed during this pass.'},
      'diff_summary': {'type': 'string', 'description': 'Concise summary of the resulting code diff.'},
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

const fileListPreset = SchemaPreset(
  name: 'file_list',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'files'),
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['items'],
    'properties': {
      'items': {
        'type': 'array',
        'description': 'List of files relevant to this step.',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['path'],
          'properties': {
            'path': {'type': 'string', 'description': 'File path relative to project root.'},
            'reason': {
              'type': ['string', 'null'],
              'description': 'Why this file is included (optional).',
            },
          },
        },
      },
    },
  },
);

const checklistPreset = SchemaPreset(
  name: 'checklist',
  format: OutputFormat.json,
  defaultResolver: InlineOutput(schemaKey: 'checklist'),
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['items', 'all_pass'],
    'properties': {
      'items': {
        'type': 'array',
        'description': 'Individual checks performed.',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['check', 'pass'],
          'properties': {
            'check': {'type': 'string', 'description': 'What was verified.'},
            'pass': {'type': 'boolean', 'description': 'Whether the check passed.'},
            'detail': {
              'type': ['string', 'null'],
              'description': 'Additional context when the check failed (optional).',
            },
          },
        },
      },
      'all_pass': {'type': 'boolean', 'description': 'True only if every item in `items` passed.'},
    },
  },
);

/// Simple scalar schema for non-negative integer counters like `findings_count`.
const nonNegativeIntegerPreset = SchemaPreset(
  name: 'non_negative_integer',
  format: OutputFormat.json,
  defaultResolver: NarrativeOutput(schemaKey: 'count'),
  fieldResolvers: {
    'confidence': NarrativeOutput(schemaKey: 'confidence'),
    'findings_count': InlineOutput(schemaKey: 'findings_count'),
    'spec_confidence': NarrativeOutput(schemaKey: 'spec_confidence'),
  },
  schema: {'type': 'integer', 'minimum': 0},
  promptFragment: 'Produce a non-negative integer (0 or greater). Output the number directly.',
);

/// Canonical text shape for `diff_summary` outputs across implementation,
/// remediation, and validation steps.
const diffSummaryPreset = SchemaPreset(
  name: 'diff_summary',
  format: OutputFormat.text,
  defaultResolver: NarrativeOutput(schemaKey: 'diff_summary'),
  schema: {'type': 'string'},
  description: 'Compact description of file-level changes produced by this step (files touched, nature of edits).',
);

/// Canonical text shape for `validation_summary` outputs emitted by verify /
/// re-validate steps.
const validationSummaryPreset = SchemaPreset(
  name: 'validation_summary',
  format: OutputFormat.text,
  defaultResolver: NarrativeOutput(schemaKey: 'validation_summary'),
  schema: {'type': 'string'},
  description: 'Summary of validation outcomes for this step (build, tests, analyzer, and any refinements applied).',
);

/// Canonical text shape for `state_update_summary` outputs emitted by
/// user-authored or legacy workflows that still include an update-state step.
const stateUpdateSummaryPreset = SchemaPreset(
  name: 'state_update_summary',
  format: OutputFormat.text,
  defaultResolver: NarrativeOutput(schemaKey: 'state_update_summary'),
  schema: {'type': 'string'},
  description: 'Summary of what was written to the project state document for this workflow execution.',
);

/// Canonical text shape for `remediation_summary` outputs emitted inside
/// remediation loops.
const remediationSummaryPreset = SchemaPreset(
  name: 'remediation_summary',
  format: OutputFormat.text,
  defaultResolver: NarrativeOutput(schemaKey: 'remediation_summary'),
  schema: {'type': 'string'},
  description:
      'Summary of what was changed during this remediation pass – issues addressed, approach taken, and any deferrals.',
);

/// Canonical text shape for per-story `story_result` outputs emitted inside
/// the plan-and-implement foreach pipeline.
const storyResultPreset = SchemaPreset(
  name: 'story_result',
  format: OutputFormat.text,
  defaultResolver: NarrativeOutput(schemaKey: 'story_result'),
  schema: {'type': 'string'},
  description:
      'Per-story result for this FIS only. Report success when scoped acceptance checks pass; unrelated sibling or baseline failures are non-blocking and should be named as external context, not as this story\'s failure.',
);

const _gatingFindingsCountDescription =
    'Count of still-unresolved findings routed to Fix (mechanically/automatically remediable), per the Fix/Note routing + Loop Convergence Signals model in references/review-verdict.md. 0 means nothing remains for automated remediation – the remediation loop reads this field to decide whether to iterate. Do NOT count Note-routed findings (design-judgment, decision, or reconciliation gaps surfaced for human review at any severity); those are never auto-applied, so counting them would deadlock the loop. Non-negative integer.';

const gatingFindingsCountPreset = SchemaPreset(
  name: 'gating_findings_count',
  format: OutputFormat.json,
  defaultResolver: NarrativeOutput(schemaKey: 'count'),
  schema: {'type': 'integer', 'minimum': 0},
  description: _gatingFindingsCountDescription,
  promptFragment: 'Produce a non-negative integer (0 or greater). Output the number directly.',
);

const findingsCountPreset = SchemaPreset(
  name: 'findings_count',
  format: OutputFormat.json,
  defaultResolver: NarrativeOutput(schemaKey: 'count'),
  schema: {'type': 'integer', 'minimum': 0},
  description: 'Number of issues flagged by this review; 0 means clean.',
  promptFragment: 'Produce a non-negative integer (0 or greater). Output the number directly.',
);

const reviewReportPathPreset = SchemaPreset(
  name: 'review_report_path',
  format: OutputFormat.path,
  schema: {'type': 'string'},
  description:
      'Path to the review report file written by the invoking review skill. The form is dictated by the skill contract: absolute when the skill writes via --output-dir outside the project root; project-root-relative when the skill follows review-report-location.md. Aggregate-reviews joins relative values under the active workspace root.',
);

const prdPathPreset = SchemaPreset(
  name: 'prd_path',
  format: OutputFormat.path,
  schema: {'type': 'string'},
  description: 'Workspace-relative path to the required PRD on disk.',
);

const planPathPreset = SchemaPreset(
  name: 'plan_path',
  format: OutputFormat.path,
  schema: {'type': 'string'},
  description:
      'Workspace-relative path to plan.json (preferred) or plan.md (legacy) on disk; empty when no plan exists yet.',
);

const fisPathPreset = SchemaPreset(
  name: 'fis_path',
  format: OutputFormat.path,
  schema: {'type': 'string'},
  description:
      'Workspace-relative path to the FIS on disk – either pre-authored when input resolves to one, or freshly synthesized by the upstream skill.',
);

const detectedFisPathPreset = SchemaPreset(
  name: 'detected_fis_path',
  format: OutputFormat.path,
  schema: {'type': 'string'},
  description: 'Workspace-relative path to the existing FIS on disk, or empty when input requires spec synthesis.',
);

const specSourcePreset = SchemaPreset(
  name: 'spec_source',
  format: OutputFormat.text,
  defaultResolver: NarrativeOutput(schemaKey: 'spec_source'),
  schema: {'type': 'string'},
  description:
      "'existing' when input resolves to a reusable FIS, 'synthesized' when the spec skill authored a new one.",
);

const specConfidencePreset = SchemaPreset(
  name: 'spec_confidence',
  format: OutputFormat.json,
  defaultResolver: NarrativeOutput(schemaKey: 'spec_confidence'),
  schema: {'type': 'integer', 'minimum': 0},
  description:
      'Self-rated 1-10 readiness of a synthesized FIS authored by the spec skill (per the Confidence Check in fis-authoring-guidelines.md). Emit 0 in every other case: at the detection step (no FIS authored yet, regardless of spec_source) and when an existing FIS is reused without synthesis. A value <7 triggers the revise-spec step.',
  promptFragment: 'Produce a non-negative integer (0 or greater). Output the number directly.',
);
