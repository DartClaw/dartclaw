import 'schema_presets.dart';
import 'workflow_definition.dart';
import 'workflow_dsl_rules.dart';

const _schemaDialect = 'https://json-schema.org/draft/2020-12/schema';
const _schemaTitle = 'DartClaw Workflow';

Map<String, Object?> emitWorkflowJsonSchema() {
  final definitions = <String, Object?>{
    'gitArtifacts': _objectSchema(WorkflowDslRules.gitArtifacts),
    'gitCleanup': _objectSchema(WorkflowDslRules.gitCleanup),
    'gitPublish': _objectSchema(WorkflowDslRules.gitPublish),
    'gitStrategy': _gitStrategySchema(),
    'gitWorktree': _objectSchema(WorkflowDslRules.gitWorktree),
    'inlineForeach': _inlineForeachSchema(),
    'inlineLoop': _inlineLoopSchema(),
    'mergeResolve': _objectSchema(WorkflowDslRules.mergeResolve),
    'output': _outputSchema(),
    'step': _stepSchema(),
    'stepDefault': _objectSchema(WorkflowDslRules.stepDefault),
    'variable': _objectSchema(WorkflowDslRules.variable),
  };
  return _sortNode({
    ..._objectSchema(
      WorkflowDslRules.workflow,
      overrides: {
        'variables': _replaceKind(
          WorkflowDslRules.workflow.field('variables'),
          WorkflowValueKind.mapping,
          _mapSchema({r'$ref': '#/\$defs/variable'}),
        ),
        'steps': _replaceKind(
          WorkflowDslRules.workflow.field('steps'),
          WorkflowValueKind.list,
          _stepsSchema(includeForeach: true),
        ),
        'stepDefaults': _replaceKind(
          WorkflowDslRules.workflow.field('stepDefaults'),
          WorkflowValueKind.list,
          _arraySchema({r'$ref': '#/\$defs/stepDefault'}),
        ),
        'gitStrategy': _replaceKind(WorkflowDslRules.workflow.field('gitStrategy'), WorkflowValueKind.mapping, {
          r'$ref': '#/\$defs/gitStrategy',
        }),
      },
    ),
    r'$defs': definitions,
    r'$schema': _schemaDialect,
    'title': _schemaTitle,
  }) as Map<String, Object?>;
}

Map<String, Object?> _stepSchema() {
  final schema = _objectSchema(
    WorkflowDslRules.step,
    overrides: {
      'outputs': _replaceKind(WorkflowDslRules.step.field('outputs'), WorkflowValueKind.mapping, _outputsMapSchema()),
    },
  );
  schema['allOf'] = [
    for (final type in WorkflowTaskType.values) _typeBranch(type),
    _defaultAgentBranch(),
    ..._mutualExclusionSchemas(WorkflowDslRules.step),
  ];
  return schema;
}

Map<String, Object?> _typeBranch(WorkflowTaskType type) => {
  'if': {
    'properties': {
      'type': {'const': type.toJson()},
    },
    'required': ['type'],
  },
  'then': _stepTypeConstraints(type),
};

Map<String, Object?> _defaultAgentBranch() => {
  'if': {
    'anyOf': [
      {
        'not': {
          'required': ['type'],
        },
      },
      {
        'properties': {
          'type': {'const': null},
        },
        'required': ['type'],
      },
    ],
  },
  'then': _stepTypeConstraints(WorkflowTaskType.agent),
};

Map<String, Object?> _stepTypeConstraints(WorkflowTaskType type) {
  final properties = <String, Object?>{};
  final forbidden = <String>[];
  final requirements = <Object?>[];
  for (final field in WorkflowDslRules.step.fields) {
    final kinds = field.acceptedKinds.where((kind) => field.acceptsKindForType(kind, type)).toSet();
    if (kinds.isEmpty) {
      forbidden.addAll(field.names);
    } else if (kinds.length != field.acceptedKinds.toSet().length) {
      final narrowed = _fieldSchema(field, kinds: kinds);
      for (final name in field.names) {
        properties[name] = narrowed;
      }
    }
    if (field.requiresValueFor(type)) {
      requirements.add(_requiresValueOneOf(WorkflowDslRules.step, field));
    }
  }
  return {
    if (properties.isNotEmpty) 'properties': properties,
    if (requirements.isNotEmpty) 'allOf': requirements,
    if (forbidden.isNotEmpty)
      'not': {
        'anyOf': [
          for (final name in forbidden)
            {
              'required': [name],
            },
        ],
      },
  };
}

Iterable<Map<String, Object?>> _mutualExclusionSchemas(WorkflowBlockRule block) sync* {
  final emitted = <String>{};
  for (final field in block.fields) {
    for (final otherName in field.mutuallyExclusiveWith) {
      final other = block.field(otherName);
      for (final name in field.names) {
        for (final alias in other.names) {
          final pair = [name, alias]..sort();
          if (emitted.add(pair.join('\u0000'))) {
            yield {
              'not': {
                'allOf': [_fieldValuePredicate(name, field), _fieldValuePredicate(alias, other)],
              },
            };
          }
        }
      }
    }
  }
}

Map<String, Object?> _inlineForeachSchema() => _objectSchema(
  WorkflowDslRules.inlineForeach,
  overrides: {
    'outputs': _replaceKind(
      WorkflowDslRules.inlineForeach.field('outputs'),
      WorkflowValueKind.mapping,
      _outputsMapSchema(),
    ),
    'steps': _replaceKind(
      WorkflowDslRules.inlineForeach.field('steps'),
      WorkflowValueKind.list,
      _stepsSchema(includeForeach: false),
    ),
  },
);

Map<String, Object?> _inlineLoopSchema() => _objectSchema(
  WorkflowDslRules.inlineLoop,
  overrides: {
    'steps': _replaceKind(
      WorkflowDslRules.inlineLoop.field('steps'),
      WorkflowValueKind.list,
      _arraySchema({r'$ref': '#/\$defs/step'}, minItems: 1),
    ),
  },
);

Map<String, Object?> _outputSchema() {
  final field = WorkflowDslRules.output.field('schema');
  return _objectSchema(
    WorkflowDslRules.output,
    overrides: {
      'schema': _schemaForKinds(
        field,
        field.acceptedKinds.toSet(),
        overrides: {
          WorkflowValueKind.string: {'enum': schemaPresets.keys.toList()..sort(), 'type': 'string'},
          WorkflowValueKind.mapping: {'type': 'object'},
        },
      ),
    },
  );
}

Map<String, Object?> _outputsMapSchema() => _mapSchema({
  'oneOf': [
    {'enum': WorkflowDslRules.outputShorthandValues.map(_enumWireValue).toList()..sort(), 'type': 'string'},
    {r'$ref': '#/\$defs/output'},
  ],
});

Map<String, Object?> _gitStrategySchema() {
  Map<String, Object?> nested(String fieldName, String definition) => _replaceKind(
    WorkflowDslRules.gitStrategy.field(fieldName),
    WorkflowValueKind.mapping,
    {r'$ref': '#/\$defs/$definition'},
  );

  final worktree = WorkflowDslRules.gitStrategy.field('worktree');
  final mergeResolve = WorkflowDslRules.gitStrategy.field('merge_resolve');
  return _objectSchema(
    WorkflowDslRules.gitStrategy,
    overrides: {
      'publish': nested('publish', 'gitPublish'),
      'cleanup': nested('cleanup', 'gitCleanup'),
      'artifacts': nested('artifacts', 'gitArtifacts'),
      'worktree': _schemaForKinds(
        worktree,
        worktree.acceptedKinds.toSet(),
        overrides: {
          WorkflowValueKind.string: {
            'enum': WorkflowGitWorktreeMode.values.map((value) => value.toJson()).toList()..sort(),
            'type': 'string',
          },
          WorkflowValueKind.mapping: {r'$ref': '#/\$defs/gitWorktree'},
        },
      ),
      'merge_resolve': _schemaForKinds(
        mergeResolve,
        mergeResolve.acceptedKinds.toSet(),
        overrides: {
          WorkflowValueKind.mapping: {r'$ref': '#/\$defs/mergeResolve'},
        },
      ),
    },
  );
}

Map<String, Object?> _stepsSchema({required bool includeForeach}) => _arraySchema({
  'oneOf': [
    {r'$ref': '#/\$defs/step'},
    if (includeForeach) {r'$ref': '#/\$defs/inlineForeach'},
    {r'$ref': '#/\$defs/inlineLoop'},
  ],
}, minItems: 1);

Map<String, Object?> _objectSchema(WorkflowBlockRule block, {Map<String, Object?> overrides = const {}}) {
  final properties = <String, Object?>{};
  final requirements = <Object?>[];
  for (final field in block.fields) {
    final valueSchema = overrides[field.names.first] ?? _fieldSchema(field);
    for (final name in field.names) {
      properties[name] = valueSchema;
    }
    if (field.required) requirements.add(_requiresOneOf(field.names));
  }
  return {
    'additionalProperties': false,
    if (requirements.isNotEmpty) 'allOf': requirements,
    'properties': properties,
    'type': 'object',
  };
}

Map<String, Object?> _requiresOneOf(List<String> names) {
  final acceptedNames = names.toList()..sort();
  if (acceptedNames.length == 1) return {'required': acceptedNames};
  return {
    'anyOf': [
      for (final name in acceptedNames)
        {
          'required': [name],
        },
    ],
  };
}

Map<String, Object?> _requiresValueOneOf(WorkflowBlockRule block, WorkflowFieldRule field) {
  final predicates = [
    for (final name in field.names) _fieldValuePredicate(name, field, ignoreNull: true),
    for (final alternative in field.alternatives)
      for (final name in block.field(alternative).names)
        _fieldValuePredicate(name, block.field(alternative), ignoreNull: true),
  ];
  if (predicates.length == 1) return predicates.single;
  return {'anyOf': predicates};
}

Map<String, Object?> _fieldValuePredicate(String name, WorkflowFieldRule field, {bool ignoreNull = false}) {
  final ignoredValues = <Object?>[...field.ignoredValues, if (ignoreNull && !field.ignoredValues.contains(null)) null];
  return {
    if (ignoredValues.isNotEmpty)
      'properties': {
        name: {
          'not': {'enum': ignoredValues},
        },
      },
    'required': [name],
  };
}

Map<String, Object?> _replaceKind(WorkflowFieldRule field, WorkflowValueKind kind, Map<String, Object?> replacement) =>
    _schemaForKinds(field, field.acceptedKinds.toSet(), overrides: {kind: replacement});

Map<String, Object?> _fieldSchema(WorkflowFieldRule field, {Set<WorkflowValueKind>? kinds}) =>
    _schemaForKinds(field, kinds ?? field.acceptedKinds.toSet());

Map<String, Object?> _schemaForKinds(
  WorkflowFieldRule field,
  Set<WorkflowValueKind> kinds, {
  Map<WorkflowValueKind, Map<String, Object?>> overrides = const {},
}) {
  final orderedKinds = kinds.toList()..sort((left, right) => left.name.compareTo(right.name));
  final hasInteger = kinds.contains(WorkflowValueKind.integer);
  final schemas = [
    for (final kind in orderedKinds)
      overrides[kind] ?? _kindSchema(kind, excludeIntegers: kind == WorkflowValueKind.number && hasInteger),
  ];
  final enumValues = field.enumValues.map(_enumWireValue).toList()..sort();
  if (enumValues.isNotEmpty) {
    for (var index = 0; index < orderedKinds.length; index++) {
      if (orderedKinds[index] == WorkflowValueKind.string) schemas[index] = {...schemas[index], 'enum': enumValues};
    }
  }
  if (schemas.length == 1) return schemas.single;
  return {'oneOf': schemas};
}

Map<String, Object?> _kindSchema(WorkflowValueKind kind, {required bool excludeIntegers}) => switch (kind) {
  WorkflowValueKind.string => {'type': 'string'},
  WorkflowValueKind.boolean => {'type': 'boolean'},
  WorkflowValueKind.integer => {'type': 'integer'},
  WorkflowValueKind.number => {
    if (excludeIntegers) 'not': {'type': 'integer'},
    'type': 'number',
  },
  WorkflowValueKind.stringList => {
    'items': {'type': 'string'},
    'type': 'array',
  },
  WorkflowValueKind.mapping => {'type': 'object'},
  WorkflowValueKind.list => {'type': 'array'},
  WorkflowValueKind.nullValue => {'type': 'null'},
};

Map<String, Object?> _arraySchema(Map<String, Object?> items, {int? minItems}) => {
  'items': items,
  'minItems': ?minItems,
  'type': 'array',
};

Map<String, Object?> _mapSchema(Map<String, Object?> values) => {'additionalProperties': values, 'type': 'object'};

String _enumWireValue(Object value) => switch (value) {
  WorkflowTaskType type => type.toJson(),
  OutputFormat format => format.name,
  SchemaPreset preset => preset.name,
  WorkflowGitWorktreeMode mode => mode.toJson(),
  MergeResolveEscalation escalation => escalation.toYamlString(),
  Enum value => value.name,
  _ => '$value',
};

Object? _sortNode(Object? node) => switch (node) {
  Map<Object?, Object?> map => {
    for (final key in map.keys.map((key) => '$key').toList()..sort()) key: _sortNode(map[key]),
  },
  List<Object?> list => [for (final value in list) _sortNode(value)],
  _ => node,
};
