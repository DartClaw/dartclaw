/// A built-in schema preset with JSON Schema and prompt fragment.
class SchemaPreset {
  /// Preset name (used in YAML: `schema: verdict`).
  final String name;

  /// JSON Schema definition.
  final Map<String, dynamic> schema;

  /// Human-readable prompt fragment appended to step prompts.
  final String promptFragment;

  const SchemaPreset({required this.name, required this.schema, required this.promptFragment});
}

/// Built-in schema presets registry.
///
/// Lookup by name: `schemaPresets['verdict']`.
const schemaPresets = <String, SchemaPreset>{
  'verdict': verdictPreset,
  'remediation-result': remediationResultPreset,
  'story-plan': storyPlanPreset,
  'file-list': fileListPreset,
  'checklist': checklistPreset,
};

const verdictPreset = SchemaPreset(
  name: 'verdict',
  schema: {
    'type': 'object',
    'required': ['pass', 'findings_count', 'findings', 'summary'],
    'properties': {
      'pass': {'type': 'boolean'},
      'findings_count': {'type': 'integer'},
      'findings': {
        'type': 'array',
        'items': {
          'type': 'object',
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
    'type': 'array',
    'items': {
      'type': 'object',
      'required': ['id', 'title', 'description', 'acceptance_criteria', 'type', 'dependencies', 'key_files', 'effort'],
      'properties': {
        'id': {'type': 'string'},
        'title': {'type': 'string'},
        'description': {'type': 'string'},
        'acceptance_criteria': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'type': {'type': 'string'},
        'phase': {'type': 'string'},
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
  promptFragment: '''Produce your output as a JSON array of story objects. Each story has:
- id (string): Short unique identifier (e.g. "s01", "s02")
- title (string): Concise story title
- description (string): What this story delivers
- acceptance_criteria (array of strings): Testable criteria
- type (string): "coding", "research", "analysis", or "writing"
- phase (string, optional): Grouping label
- dependencies (array of strings): IDs of stories this depends on
- key_files (array of strings): Primary files affected
- effort (string): "small", "medium", or "large"

Output the JSON directly — do not wrap in markdown code fences.''',
);

const remediationResultPreset = SchemaPreset(
  name: 'remediation-result',
  schema: {
    'type': 'object',
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

const fileListPreset = SchemaPreset(
  name: 'file-list',
  schema: {
    'type': 'array',
    'items': {
      'type': 'object',
      'required': ['path'],
      'properties': {
        'path': {'type': 'string'},
        'reason': {'type': 'string'},
      },
    },
  },
  promptFragment: '''Produce your output as a JSON array of file objects. Each has:
- path (string): File path relative to project root
- reason (string, optional): Why this file is included

Output the JSON directly — do not wrap in markdown code fences.''',
);

const checklistPreset = SchemaPreset(
  name: 'checklist',
  schema: {
    'type': 'object',
    'required': ['items', 'all_pass'],
    'properties': {
      'items': {
        'type': 'array',
        'items': {
          'type': 'object',
          'required': ['check', 'pass'],
          'properties': {
            'check': {'type': 'string'},
            'pass': {'type': 'boolean'},
            'detail': {'type': 'string'},
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
