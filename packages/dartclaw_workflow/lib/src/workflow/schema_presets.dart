/// A built-in schema preset with JSON Schema and prompt fragment.
class SchemaPreset {
  /// Preset name (used in YAML: `schema: verdict`).
  final String name;

  /// JSON Schema definition.
  final Map<String, dynamic> schema;

  /// Human-readable prompt fragment appended to step prompts for JSON outputs.
  ///
  /// Null for presets that only apply to `format: text` outputs — those do not
  /// render a schema section, so a prompt fragment would be dead code.
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
      'pass': {'type': 'boolean'},
      'findings_count': {'type': 'integer'},
      'findings': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['severity', 'location', 'description'],
          'properties': {
            'severity': {
              'type': 'string',
              'enum': ['critical', 'high', 'medium', 'low'],
            },
            'location': {'type': 'string'},
            'description': {'type': 'string'},
          },
        },
      },
      'summary': {'type': 'string'},
    },
  },
  promptFragment: '''Produce your final output as a JSON object with these fields:
- pass (boolean): Whether the review passes overall
- findings_count (integer): Total number of findings
- findings (array): Each finding has:
  - severity: "critical", "high", "medium", or "low"
  - location: File path and line reference
  - description: What the issue is and why it matters
- summary (string): 2-3 sentence overall assessment

Output the JSON directly — do not wrap in markdown code fences.''',
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
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'id',
            'title',
            'description',
            'acceptance_criteria',
            'type',
            'phase',
            'dependencies',
            'key_files',
            'effort',
          ],
          'properties': {
            'id': {'type': 'string'},
            'title': {'type': 'string'},
            'description': {'type': 'string'},
            'acceptance_criteria': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'type': {'type': 'string'},
            'phase': {
              'type': ['string', 'null'],
            },
            'dependencies': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'key_files': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'effort': {'type': 'string'},
          },
        },
      },
    },
  },
  promptFragment: '''Produce your output as a JSON object with an `items` array of story objects. Each story has:
- id (string): Short unique identifier (e.g. "s01", "s02")
- title (string): Concise story title
- description (string): What this story delivers
- acceptance_criteria (array of strings): Testable criteria
- type (string): "coding", "research", "analysis", or "writing"
- phase (string, optional): Grouping label
- dependencies (array of strings): IDs of stories this depends on
- key_files (array of strings): Primary files affected
- effort (string): "small", "medium", or "large"

Return the object directly — do not wrap in markdown code fences.''',
);

const remediationResultPreset = SchemaPreset(
  name: 'remediation-result',
  schema: {
    'type': 'object',
    'additionalProperties': false,
    'required': ['remediation_summary', 'diff_summary'],
    'properties': {
      'remediation_summary': {'type': 'string'},
      'diff_summary': {'type': 'string'},
    },
  },
  promptFragment: '''Produce your final output as a JSON object with these fields:
- remediation_summary (string): What was re-validated and changed
- diff_summary (string): A concise summary of the resulting code diff

Output the JSON directly — do not wrap in markdown code fences.''',
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
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'id',
            'title',
            'description',
            'acceptance_criteria',
            'type',
            'phase',
            'dependencies',
            'key_files',
            'effort',
            'spec',
            'story_id',
            'classification',
            'path',
          ],
          'properties': {
            'id': {'type': 'string'},
            'title': {'type': 'string'},
            'description': {'type': 'string'},
            'acceptance_criteria': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'type': {'type': 'string'},
            'phase': {
              'type': ['string', 'null'],
            },
            'dependencies': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'key_files': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'effort': {'type': 'string'},
            'spec': {'type': 'string'},
            'story_id': {
              'type': ['string', 'null'],
            },
            'classification': {
              'type': ['string', 'null'],
            },
            'path': {
              'type': ['string', 'null'],
            },
          },
        },
      },
    },
  },
  promptFragment: '''Produce your output as a JSON object with an `items` array of story spec objects. Each item has:
- id (string): Story identifier used by downstream foreach steps
- title (string): Concise story title
- description (string): Story summary from the plan
- acceptance_criteria (array of strings): Structured criteria preserved for downstream review
- type (string): Story type such as "coding" or "analysis"
- phase (string, optional): Grouping label
- dependencies (array of strings): Story IDs this spec depends on
- key_files (array of strings): Primary files affected by the story
- effort (string): Story effort label
- spec (string): Full story specification text used by implementation steps
- story_id (string, optional): Legacy compatibility field if needed
- classification (string, optional): Spec classification such as THIN, STANDARD, or COMPOSITE
- path (string, optional): Relative path to any persisted spec artifact

Return the object directly — do not wrap in markdown code fences.''',
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
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['path', 'reason'],
          'properties': {
            'path': {'type': 'string'},
            'reason': {
              'type': ['string', 'null'],
            },
          },
        },
      },
    },
  },
  promptFragment: '''Produce your output as a JSON object with an `items` array of file objects. Each item has:
- path (string): File path relative to project root
- reason (string, optional): Why this file is included

Return the object directly — do not wrap in markdown code fences.''',
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
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['check', 'pass', 'detail'],
          'properties': {
            'check': {'type': 'string'},
            'pass': {'type': 'boolean'},
            'detail': {
              'type': ['string', 'null'],
            },
          },
        },
      },
      'all_pass': {'type': 'boolean'},
    },
  },
  promptFragment: '''Produce your output as a JSON object with:
- items (array): Each item has:
  - check (string): What was verified
  - pass (boolean): Whether it passed
  - detail (string, optional): Additional context
- all_pass (boolean): true only if every item passed

Output the JSON directly — do not wrap in markdown code fences.''',
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
      'framework': {'type': 'string'},
      'project_root': {'type': 'string'},
      'document_locations': {
        'type': 'object',
        'additionalProperties': false,
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
          },
          'backlog': {
            'type': ['string', 'null'],
          },
          'roadmap': {
            'type': ['string', 'null'],
          },
          'prd': {
            'type': ['string', 'null'],
          },
          'plan': {
            'type': ['string', 'null'],
          },
          'spec': {
            'type': ['string', 'null'],
          },
          'state': {
            'type': ['string', 'null'],
          },
          'readme': {
            'type': ['string', 'null'],
          },
          'agent_rules': {
            'type': ['string', 'null'],
          },
          'architecture': {
            'type': ['string', 'null'],
          },
          'guide': {
            'type': ['string', 'null'],
          },
        },
      },
      'state_protocol': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['type', 'state_file', 'format'],
        'properties': {
          'type': {
            'type': ['string', 'null'],
          },
          'state_file': {
            'type': ['string', 'null'],
          },
          'format': {
            'type': ['string', 'null'],
          },
        },
      },
    },
  },
  promptFragment: '''Produce your output as a JSON object describing the project layout:
- framework (string): Detected project framework or "none"
- project_root (string): Absolute or repo-relative project root
- document_locations (object): Map of document kind → path (e.g. product, plan, state)
- state_protocol (object): How project state is tracked (e.g. state_file path, format)

Output the JSON directly — do not wrap in markdown code fences.''',
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
  description: 'Summary of what was changed during this remediation pass — issues addressed, approach taken, and any deferrals.',
);

/// Canonical text shape for per-story `story_result` outputs emitted inside
/// the plan-and-implement foreach pipeline.
const storyResultPreset = SchemaPreset(
  name: 'story-result',
  schema: {'type': 'string'},
  description: 'Summary of what was implemented for this story — files changed, key decisions, and verification notes.',
);
