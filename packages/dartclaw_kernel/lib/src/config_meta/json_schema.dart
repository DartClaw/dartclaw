part of '../config_meta.dart';

/// Dialect the emitted artifact declares. No conditional keyword is emitted,
/// so the same bytes behave identically under a draft-07 reader.
const String _schemaDialect = 'https://json-schema.org/draft/2020-12/schema';

const String _schemaTitle = 'DartClaw configuration';

/// Reload tier as description text. The operator guide renders these bytes
/// verbatim, so the four strings are a contract rather than formatting —
/// and exhaustive, so a fifth tier fails to compile instead of at generation.
String _tierSuffix(ConfigMutability mutability) => switch (mutability) {
  ConfigMutability.live => ' (live)',
  ConfigMutability.reloadable => ' (reload)',
  ConfigMutability.restart => ' (restart required)',
  ConfigMutability.readonly => ' (file-only, not settable via API or CLI)',
};

/// One registered declaration, flattened so a [FieldMeta] and an
/// [EntryFieldMeta] project through the same code.
///
/// [tierSuffix] travels with the declaration because an entry field carries no
/// mutability of its own — the container it lives in decides its tier.
///
/// [operatorNamed] separates the two readings of [ConfigFieldType.objectMap]
/// the registry uses: a *field* declared that way is keyed by an
/// operator-chosen name, while an *entry field* declared that way is a nested
/// object whose keys the shape names. `ConfigMeta`'s own coverage gate reads
/// them the same way.
typedef _Declaration = ({
  bool operatorNamed,
  ConfigFieldType type,
  ConfigFieldType? alsoAccepts,
  String description,
  String tierSuffix,
  bool nullable,
  int? min,
  int? max,
  List<String>? allowedValues,
  ConfigEntryShape? entry,
});

Map<String, Object?> _buildConfigJsonSchema() {
  final root = _objectSchema({for (final field in ConfigMeta.fields.values) field.yamlPath: _declarationOf(field)});
  return _sortKeys({...root, r'$schema': _schemaDialect, 'title': _schemaTitle});
}

_Declaration _declarationOf(FieldMeta field) => (
  operatorNamed: true,
  type: field.type,
  alsoAccepts: field.alsoAccepts,
  description: field.description,
  tierSuffix: _tierSuffix(field.mutability),
  nullable: field.nullable,
  min: field.min,
  max: field.max,
  allowedValues: field.allowedValues,
  entry: field.entry,
);

_Declaration _entryDeclarationOf(EntryFieldMeta field, String tierSuffix) => (
  operatorNamed: false,
  type: field.type,
  alsoAccepts: field.alsoAccepts,
  description: field.description,
  tierSuffix: tierSuffix,
  nullable: field.nullable,
  min: field.min,
  max: field.max,
  allowedValues: field.allowedValues,
  entry: field.entry,
);

/// Builds one closed object schema from a flat map of dotted paths.
///
/// A path that is both a declared leaf and the prefix of others — the way the
/// registry declares a value that is either a scalar or a mapping — yields one
/// node carrying both arms.
Map<String, Object?> _objectSchema(Map<String, _Declaration> flat) {
  final leaves = <String, _Declaration>{};
  final subtrees = <String, Map<String, _Declaration>>{};
  for (final entry in flat.entries) {
    final dot = entry.key.indexOf('.');
    if (dot < 0) {
      leaves[entry.key] = entry.value;
    } else {
      (subtrees[entry.key.substring(0, dot)] ??= {})[entry.key.substring(dot + 1)] = entry.value;
    }
  }

  final properties = <String, Object?>{};
  for (final key in {...leaves.keys, ...subtrees.keys}.toList()..sort()) {
    properties[key] = _nodeSchema(leaves[key], subtrees[key]);
  }
  return {'additionalProperties': false, 'properties': properties, 'type': 'object'};
}

Map<String, Object?> _nodeSchema(_Declaration? leaf, Map<String, _Declaration>? subtree) {
  final node = <String, Object?>{};
  final types = <String>{};

  if (leaf != null) {
    node['description'] = leaf.description + leaf.tierSuffix;
    types.add(_jsonType(leaf.type));
    if (leaf.alsoAccepts case final alternative?) types.add(_jsonType(alternative));
    if (leaf.nullable) types.add('null');
    if (_enumOf(leaf) case final values?) node['enum'] = values;
    if (leaf.min case final min?) node['minimum'] = min;
    if (leaf.max case final max?) node['maximum'] = max;
    switch (leaf.type) {
      case ConfigFieldType.stringList:
        node['items'] = {'type': 'string'};
      case ConfigFieldType.objectList:
        node['items'] = _entrySchema(leaf.entry, leaf.tierSuffix);
      case ConfigFieldType.objectMap:
        final entry = _entrySchema(leaf.entry, leaf.tierSuffix);
        if (leaf.operatorNamed) {
          node['additionalProperties'] = entry;
        } else {
          // Inlined as a nested object: it contributes shape, never the node's
          // own description or constraints.
          if (entry['properties'] case final properties?) node['properties'] = properties;
          if (entry['additionalProperties'] case final additional?) node['additionalProperties'] = additional;
        }
      case ConfigFieldType.int_:
      case ConfigFieldType.double_:
      case ConfigFieldType.string:
      case ConfigFieldType.bool_:
      case ConfigFieldType.enum_:
        break;
    }
  }

  if (subtree != null) {
    types.add('object');
    // A section the emitter synthesised carries no declaration, so the emitter
    // owns its nullability: YAML lets an operator leave a section body empty
    // and the loader reads that as absent, so refusing it would flag a legal
    // file. A *declared* field's nullability stays the registry's answer.
    if (leaf == null) types.add('null');
    // An exactly declared path under an object-valued node wins: it lands
    // beside the entry shape rather than replacing it.
    final declared = (node['properties'] as Map<String, Object?>?) ?? const {};
    final nested = _objectSchema(subtree)['properties']! as Map<String, Object?>;
    node['properties'] = _sortKeys({...declared, ...nested});
    node.putIfAbsent('additionalProperties', () => false);
  }

  node['type'] = types.length == 1 ? types.single : (types.toList()..sort());
  return _sortKeys(node);
}

/// Every literal the node accepts, or null when it constrains no value set.
///
/// `enum` applies to an instance of any type, so a union arm admitting
/// literals the enumerated arm does not name has to contribute them, or the
/// widened `type` would accept nothing new. A nullable enumerated field is the
/// same case: without `null` in the set, the one way to unset the field is
/// refused.
List<Object?>? _enumOf(_Declaration leaf) {
  final allowed = leaf.allowedValues;
  if (allowed == null) return null;
  final values = <Object?>[
    ...allowed,
    if (leaf.alsoAccepts == ConfigFieldType.bool_) ...[true, false],
    if (leaf.nullable) null,
  ];
  values.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  return values;
}

Map<String, Object?> _entrySchema(ConfigEntryShape? shape, String tierSuffix) => switch (shape) {
  ObjectEntry(:final fields) => _objectSchema({
    for (final field in fields.entries) field.key: _entryDeclarationOf(field.value, tierSuffix),
  }),
  ValueEntry(:final value) => _nodeSchema(_entryDeclarationOf(value, tierSuffix), null),
  // Keys defined outside this registry: described as an object and nothing more.
  OpaqueEntry() || null => {'type': 'object'},
};

String _jsonType(ConfigFieldType type) => switch (type) {
  ConfigFieldType.int_ => 'integer',
  ConfigFieldType.double_ => 'number',
  ConfigFieldType.string || ConfigFieldType.enum_ => 'string',
  ConfigFieldType.bool_ => 'boolean',
  ConfigFieldType.stringList || ConfigFieldType.objectList => 'array',
  ConfigFieldType.objectMap => 'object',
};

/// Sorts keys so the artifact is a function of registry *content*, not of
/// declaration order — reordering `ConfigMeta` must leave the bytes identical.
Map<String, Object?> _sortKeys(Map<String, Object?> node) => {
  for (final key in node.keys.toList()..sort()) key: node[key],
};
