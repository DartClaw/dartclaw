const storySpecsSchemaBody = {
  'additionalProperties': false,
  'required': ['items'],
  'properties': {
    'items': {
      'type': 'array',
      'description': 'Per-story records used as the foreach iteration source.',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['id', 'title', 'spec_path', 'dependencies'],
        'properties': {
          'id': {'type': 'string', 'description': 'Story identifier used by downstream foreach steps.'},
          'title': {'type': 'string', 'description': 'Concise story title for display and logs.'},
          'spec_path': {
            'type': 'string',
            'description': 'Workspace-relative argument-safe path to the authoritative story-spec markdown file.',
          },
          'dependencies': {
            'type': 'array',
            'description': 'Ordered prerequisite story IDs for dependency-aware fan-out.',
            'items': {'type': 'string'},
          },
          'parallel': {'type': 'boolean', 'description': 'Whether this story may run in parallel with wave siblings.'},
          'wave': {'type': 'string', 'description': 'Wave identifier from the source plan.'},
          'phase': {'type': 'string', 'description': 'Phase identifier from the source plan.'},
          'risk': {
            'type': 'string',
            'enum': ['low', 'medium', 'high'],
            'description': 'Risk level from the source plan.',
          },
          'status': {'type': 'string', 'description': 'Lifecycle status from the source plan; opaque to the engine.'},
          'spec_source': {
            'type': 'string',
            'description':
                'How the story spec was obtained; conventionally "existing" (reused from disk) or "synthesized" '
                '(produced by the plan step).',
          },
          'spec_confidence': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 10,
            'description':
                'Planner confidence for synthesized story-spec content. Meaningful only when spec_source is '
                'synthesized.',
          },
        },
      },
    },
  },
};

const storySpecsSchema = {'type': 'object', ...storySpecsSchemaBody};
