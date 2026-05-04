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
          'spec_path': {'type': 'string', 'description': 'Workspace-relative path to the authoritative FIS file.'},
          'dependencies': {
            'type': 'array',
            'description': 'Ordered prerequisite story IDs for dependency-aware fan-out.',
            'items': {'type': 'string'},
          },
        },
      },
    },
  },
};

const storySpecsSchema = {'type': 'object', ...storySpecsSchemaBody};

const nullableStorySpecsSchema = {
  'type': ['object', 'null'],
  ...storySpecsSchemaBody,
  'description': 'Story-spec records parsed from the active plan.',
};
