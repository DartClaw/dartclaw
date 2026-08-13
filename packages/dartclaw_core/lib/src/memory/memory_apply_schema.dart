/// Closed JSON Schema for one `memory_apply` operation.
const memoryApplyOperationSchema = <String, dynamic>{
  'oneOf': [_add, _revise, _merge, _remove],
};

const _correlation = <String, dynamic>{
  'correlationId': {'type': 'string', 'minLength': 1},
};
const _target = <String, dynamic>{
  'targetId': {'type': 'string', 'format': 'uuid'},
  'expectedEntryRevision': {'type': 'integer', 'minimum': 1},
};
const _replacement = <String, dynamic>{
  'topic': {'type': 'string', 'maxLength': 64, 'pattern': r'^[a-z0-9]+(?:-[a-z0-9]+)*$'},
  'content': {'type': 'string', 'minLength': 1},
  'state': {
    'type': 'string',
    'enum': ['active', 'archived'],
  },
};
const _add = <String, dynamic>{
  'type': 'object',
  'properties': {
    ..._correlation,
    'kind': {'const': 'add'},
    'topic': {'type': 'string', 'maxLength': 64, 'pattern': r'^[a-z0-9]+(?:-[a-z0-9]+)*$'},
    'content': {'type': 'string', 'minLength': 1},
  },
  'required': ['kind', 'correlationId', 'topic', 'content'],
  'additionalProperties': false,
};
const _revise = <String, dynamic>{
  'type': 'object',
  'properties': {
    ..._correlation,
    ..._target,
    ..._replacement,
    'kind': {'const': 'revise'},
  },
  'required': ['kind', 'correlationId', 'targetId', 'expectedEntryRevision', 'topic', 'content', 'state'],
  'additionalProperties': false,
};
const _merge = <String, dynamic>{
  'type': 'object',
  'properties': {
    ..._correlation,
    ..._target,
    ..._replacement,
    'kind': {'const': 'merge'},
    'sources': {
      'type': 'array',
      'minItems': 1,
      'items': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'format': 'uuid'},
          'expectedEntryRevision': {'type': 'integer', 'minimum': 1},
        },
        'required': ['id', 'expectedEntryRevision'],
        'additionalProperties': false,
      },
    },
    'reason': {'type': 'string', 'minLength': 1, 'maxLength': 1024},
  },
  'required': [
    'kind',
    'correlationId',
    'targetId',
    'expectedEntryRevision',
    'sources',
    'topic',
    'content',
    'state',
    'reason',
  ],
  'additionalProperties': false,
};
const _remove = <String, dynamic>{
  'type': 'object',
  'properties': {
    ..._correlation,
    ..._target,
    'kind': {'const': 'remove'},
    'reason': {'type': 'string', 'minLength': 1, 'maxLength': 1024},
  },
  'required': ['kind', 'correlationId', 'targetId', 'expectedEntryRevision', 'reason'],
  'additionalProperties': false,
};
