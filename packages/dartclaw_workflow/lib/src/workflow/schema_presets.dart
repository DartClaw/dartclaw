import 'package:dartclaw_core/dartclaw_core.dart' show OutputConfig, OutputFormat;

import 'output_resolver.dart';
import 'story_specs_schema.dart';

/// A built-in schema preset with JSON Schema and prompt fragment.
class SchemaPreset {
  /// Preset name (used in YAML: `schema: verdict`).
  final String name;

  /// JSON Schema definition. Per-property `description` fields drive prompt
  /// generation for JSON presets — see `PromptAugmenter._writeProperties`.
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
    'prd' || 'prd_path' => '**/prd.md',
    'plan' || 'plan_path' => '**/plan.md',
    'technical_research' || 'technical_research_path' => '**/.technical-research.md',
    'fis_paths' || 'story_spec_paths' => 'fis/s*.md',
    'spec_path' || 'story_spec' || 'story_spec_path' => '**/*.md',
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
const schemaPresets = <String, SchemaPreset>{
  'verdict': verdictPreset,
  'remediation-result': remediationResultPreset,
  'story-plan': storyPlanPreset,
  'story-specs': storySpecsPreset,
  'file-list': fileListPreset,
  'checklist': checklistPreset,
  'project-index': projectIndexPreset,
  'non-negative-integer': nonNegativeIntegerPreset,
  'diff-summary': diffSummaryPreset,
  'validation-summary': validationSummaryPreset,
  'state-update-summary': stateUpdateSummaryPreset,
  'remediation-summary': remediationSummaryPreset,
  'story-result': storyResultPreset,
};

const verdictPreset = SchemaPreset(
  name: 'verdict',
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
  name: 'story-plan',
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
  name: 'remediation-result',
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
  name: 'story-specs',
  defaultResolver: InlineOutput(schemaKey: 'story_specs'),
  fieldResolvers: {'story_specs': InlineOutput(schemaKey: 'story_specs')},
  schema: storySpecsSchema,
);

const fileListPreset = SchemaPreset(
  name: 'file-list',
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

/// Shape emitted by the `dartclaw-discover-project` skill and consumed as
/// `project_index` by downstream workflow steps.
const projectIndexPreset = SchemaPreset(
  name: 'project-index',
  defaultResolver: InlineOutput(schemaKey: 'project_index'),
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['framework', 'project_root', 'document_locations', 'state_protocol'],
    'properties': {
      'framework': {
        'type': 'string',
        'description': 'Detected project framework (e.g. "andthen", "spec-kit"), or "none".',
      },
      'project_root': {'type': 'string', 'description': 'Absolute or repo-relative path to the project root.'},
      'document_locations': {
        'type': 'object',
        'additionalProperties': false,
        'description':
            'Map of canonical document kind to workspace-relative path. '
            'Each value is the path the document should live at even when the file is missing.',
        'required': [
          'product',
          'backlog',
          'roadmap',
          'prd',
          'plan',
          'spec',
          'state',
          'readme',
          'agent_rules',
          'architecture',
          'guide',
        ],
        'properties': {
          'product': {
            'type': ['string', 'null'],
            'description': 'Product vision document.',
          },
          'backlog': {
            'type': ['string', 'null'],
            'description': 'Product backlog.',
          },
          'roadmap': {
            'type': ['string', 'null'],
            'description': 'Roadmap or milestone plan.',
          },
          'prd': {
            'type': ['string', 'null'],
            'description': 'Active milestone PRD.',
          },
          'plan': {
            'type': ['string', 'null'],
            'description': 'Active milestone plan.',
          },
          'spec': {
            'type': ['string', 'null'],
            'description': 'Active FIS / spec directory or file.',
          },
          'state': {
            'type': ['string', 'null'],
            'description': 'State-tracking document (e.g. STATE.md).',
          },
          'readme': {
            'type': ['string', 'null'],
            'description': 'Project README.',
          },
          'agent_rules': {
            'type': ['string', 'null'],
            'description': 'Project-level agent instructions (CLAUDE.md / AGENTS.md).',
          },
          'architecture': {
            'type': ['string', 'null'],
            'description': 'Architecture documentation root.',
          },
          'guide': {
            'type': ['string', 'null'],
            'description': 'Contributor / developer guide.',
          },
        },
      },
      'state_protocol': {
        'type': 'object',
        'additionalProperties': false,
        'description': 'How project state transitions are recorded.',
        'required': ['type', 'state_file', 'format'],
        'properties': {
          'type': {
            'type': ['string', 'null'],
            'description': 'State protocol identifier (e.g. "andthen-state", "none").',
          },
          'state_file': {
            'type': ['string', 'null'],
            'description': 'Path to the state file when one is tracked.',
          },
          'format': {
            'type': ['string', 'null'],
            'description': 'Encoding format (e.g. "markdown", "json").',
          },
        },
      },
      'project_name': {
        'type': ['string', 'null'],
        'description': 'Human-readable project name, when derivable from the root instruction files.',
      },
      'detected_markers': {
        'type': ['array', 'null'],
        'description': 'Framework markers that were observed during detection (e.g. `.specify/`, `docs/STATE.md`).',
        'items': {'type': 'string'},
      },
      'active_milestone': {
        'type': ['string', 'null'],
        'description': 'Current milestone identifier (e.g. "0.16.5"), or `null` when unresolved.',
      },
      'active_prd': {
        'type': ['string', 'null'],
        'description': 'Workspace-relative PRD path for the active milestone, or `null` when absent.',
      },
      'active_plan': {
        'type': ['string', 'null'],
        'description': 'Workspace-relative plan path for the active milestone, or `null` when absent.',
      },
      'active_story_specs': nullableStorySpecsSchema,
      'artifact_locations': {
        'type': ['object', 'null'],
        'description':
            'Canonical artifact-write paths (`prd`, `plan`, `fis_dir`). Each value is workspace-relative or `null`.',
        'additionalProperties': {
          'type': ['string', 'null'],
        },
      },
      'notes': {
        'type': ['string', 'null'],
        'description':
            'Free-form notes, e.g. cross-repo relationships that cannot be expressed in `document_locations`.',
      },
    },
  },
);

/// Simple scalar schema for non-negative integer counters like `findings_count`.
const nonNegativeIntegerPreset = SchemaPreset(
  name: 'non-negative-integer',
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
  name: 'diff-summary',
  defaultResolver: NarrativeOutput(schemaKey: 'diff_summary'),
  schema: {'type': 'string'},
  description: 'Compact description of file-level changes produced by this step (files touched, nature of edits).',
);

/// Canonical text shape for `validation_summary` outputs emitted by verify /
/// re-validate steps.
const validationSummaryPreset = SchemaPreset(
  name: 'validation-summary',
  defaultResolver: NarrativeOutput(schemaKey: 'validation_summary'),
  schema: {'type': 'string'},
  description: 'Summary of validation outcomes for this step (build, tests, analyzer, and any refinements applied).',
);

/// Canonical text shape for `state_update_summary` outputs emitted by the
/// final `update-state` step of every workflow.
const stateUpdateSummaryPreset = SchemaPreset(
  name: 'state-update-summary',
  defaultResolver: NarrativeOutput(schemaKey: 'state_update_summary'),
  schema: {'type': 'string'},
  description: 'Summary of what was written to the project state document for this workflow execution.',
);

/// Canonical text shape for `remediation_summary` outputs emitted inside
/// remediation loops.
const remediationSummaryPreset = SchemaPreset(
  name: 'remediation-summary',
  defaultResolver: NarrativeOutput(schemaKey: 'remediation_summary'),
  schema: {'type': 'string'},
  description:
      'Summary of what was changed during this remediation pass — issues addressed, approach taken, and any deferrals.',
);

/// Canonical text shape for per-story `story_result` outputs emitted inside
/// the plan-and-implement foreach pipeline.
const storyResultPreset = SchemaPreset(
  name: 'story-result',
  defaultResolver: NarrativeOutput(schemaKey: 'story_result'),
  schema: {'type': 'string'},
  description: 'Summary of what was implemented for this story — files changed, key decisions, and verification notes.',
);
