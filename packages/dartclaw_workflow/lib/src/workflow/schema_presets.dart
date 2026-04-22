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

  const SchemaPreset({required this.name, required this.schema, this.promptFragment, this.description});
}

/// Built-in schema presets registry.
///
/// Lookup by name: `schemaPresets['verdict']`.
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
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['pass', 'findings_count', 'findings', 'summary'],
    'properties': {
      'pass': {
        'type': 'boolean',
        'description': 'Whether the review passes overall.',
      },
      'findings_count': {
        'type': 'integer',
        'description': 'Total number of findings in `findings`.',
      },
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
            'location': {
              'type': 'string',
              'description': 'File path and line reference.',
            },
            'description': {
              'type': 'string',
              'description': 'What the issue is and why it matters.',
            },
          },
        },
      },
      'summary': {
        'type': 'string',
        'description': '2-3 sentence overall assessment.',
      },
    },
  },
);

const storyPlanPreset = SchemaPreset(
  name: 'story-plan',
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
            'id': {
              'type': 'string',
              'description': 'Short unique identifier (e.g. "s01").',
            },
            'title': {
              'type': 'string',
              'description': 'Concise story title.',
            },
            'description': {
              'type': 'string',
              'description': 'One-sentence summary of what this story delivers.',
            },
          },
        },
      },
    },
  },
);

const remediationResultPreset = SchemaPreset(
  name: 'remediation-result',
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['remediation_summary', 'diff_summary'],
    'properties': {
      'remediation_summary': {
        'type': 'string',
        'description': 'What was re-validated and changed during this pass.',
      },
      'diff_summary': {
        'type': 'string',
        'description': 'Concise summary of the resulting code diff.',
      },
    },
  },
);

const storySpecsPreset = SchemaPreset(
  name: 'story-specs',
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['items'],
    'properties': {
      'items': {
        'type': 'array',
        'description': 'Per-story records used as the foreach iteration source. '
            'Downstream steps read the authoritative FIS body (including '
            'acceptance criteria) from `spec_path`.',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['id', 'title', 'spec_path'],
          'properties': {
            'id': {
              'type': 'string',
              'description': 'Story identifier used by downstream foreach steps (e.g. "s01").',
            },
            'title': {
              'type': 'string',
              'description': 'Concise story title for display and logs.',
            },
            'spec_path': {
              'type': 'string',
              'description': 'Workspace-relative path to the FIS file — the authoritative spec body lives here.',
            },
          },
        },
      },
    },
  },
);

const fileListPreset = SchemaPreset(
  name: 'file-list',
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
            'path': {
              'type': 'string',
              'description': 'File path relative to project root.',
            },
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
            'check': {
              'type': 'string',
              'description': 'What was verified.',
            },
            'pass': {
              'type': 'boolean',
              'description': 'Whether the check passed.',
            },
            'detail': {
              'type': ['string', 'null'],
              'description': 'Additional context when the check failed (optional).',
            },
          },
        },
      },
      'all_pass': {
        'type': 'boolean',
        'description': 'True only if every item in `items` passed.',
      },
    },
  },
);

/// Shape emitted by the `dartclaw-discover-project` skill and consumed as
/// `project_index` by downstream workflow steps.
const projectIndexPreset = SchemaPreset(
  name: 'project-index',
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['framework', 'project_root', 'document_locations', 'state_protocol'],
    'properties': {
      'framework': {
        'type': 'string',
        'description': 'Detected project framework (e.g. "andthen", "spec-kit"), or "none".',
      },
      'project_root': {
        'type': 'string',
        'description': 'Absolute or repo-relative path to the project root.',
      },
      'document_locations': {
        'type': 'object',
        'additionalProperties': false,
        'description': 'Map of canonical document kind to workspace-relative path. '
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
      'artifact_locations': {
        'type': ['object', 'null'],
        'description': 'Canonical artifact-write paths (`prd`, `plan`, `fis_dir`). Each value is workspace-relative or `null`.',
        'additionalProperties': {
          'type': ['string', 'null'],
        },
      },
      'notes': {
        'type': ['string', 'null'],
        'description': 'Free-form notes, e.g. cross-repo relationships that cannot be expressed in `document_locations`.',
      },
    },
  },
);

/// Simple scalar schema for non-negative integer counters like `findings_count`.
const nonNegativeIntegerPreset = SchemaPreset(
  name: 'non-negative-integer',
  schema: {'type': 'integer', 'minimum': 0},
  promptFragment: 'Produce a non-negative integer (0 or greater). Output the number directly.',
);

/// Canonical text shape for `diff_summary` outputs across implementation,
/// remediation, and validation steps.
const diffSummaryPreset = SchemaPreset(
  name: 'diff-summary',
  schema: {'type': 'string'},
  description: 'Compact description of file-level changes produced by this step (files touched, nature of edits).',
);

/// Canonical text shape for `validation_summary` outputs emitted by verify /
/// re-validate steps.
const validationSummaryPreset = SchemaPreset(
  name: 'validation-summary',
  schema: {'type': 'string'},
  description: 'Summary of validation outcomes for this step (build, tests, analyzer, and any refinements applied).',
);

/// Canonical text shape for `state_update_summary` outputs emitted by the
/// final `update-state` step of every workflow.
const stateUpdateSummaryPreset = SchemaPreset(
  name: 'state-update-summary',
  schema: {'type': 'string'},
  description: 'Summary of what was written to the project state document for this workflow execution.',
);

/// Canonical text shape for `remediation_summary` outputs emitted inside
/// remediation loops.
const remediationSummaryPreset = SchemaPreset(
  name: 'remediation-summary',
  schema: {'type': 'string'},
  description:
      'Summary of what was changed during this remediation pass — issues addressed, approach taken, and any deferrals.',
);

/// Canonical text shape for per-story `story_result` outputs emitted inside
/// the plan-and-implement foreach pipeline.
const storyResultPreset = SchemaPreset(
  name: 'story-result',
  schema: {'type': 'string'},
  description: 'Summary of what was implemented for this story — files changed, key decisions, and verification notes.',
);
