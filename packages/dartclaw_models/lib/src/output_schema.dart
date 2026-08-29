import 'dart:convert';

/// A single failure found while validating an instance against an output schema.
///
/// Carries the diagnostic location in the *instance* — the empty string for
/// the root. Schema-declared paths use RFC 6901. An unknown property uses a
/// stable `unknown-<fingerprint>` segment so its attacker-authored name cannot
/// inject content into the error. [message] never echoes instance content.
class OutputSchemaViolation {
  /// Diagnostic location of the offending value in the validated instance.
  final String pointer;

  /// What is wrong at [pointer], stated without quoting instance content.
  final String message;

  /// Creates a violation at [pointer] described by [message].
  const new(this.pointer, this.message);

  @override
  String toString() => 'OutputSchemaViolation($pointer: $message)';
}

/// Type names accepted by [parseOutputSchema].
const _types = {'object', 'array', 'string', 'number', 'integer', 'boolean', 'null'};
const _scalarTypes = {'string', 'number', 'integer', 'boolean', 'null'};

/// Keywords accepted at parse time and dropped from the enforced form.
const _annotations = {'title', 'description', r'$schema'};

/// Keywords the validator enforces.
const _supported = {'type', 'properties', 'required', 'items', 'enum', 'additionalProperties'};

/// Parses an operator-declared output schema into its enforced, deep-closed form.
///
/// Accepts the supported keyword subset only — `type`, `properties`, `required`,
/// `items`, `enum`, `additionalProperties`, plus the ignored annotations `title`,
/// `description` and `$schema`. Anything else is rejected here rather than
/// silently unenforced at validation time.
///
/// Every object level in the returned schema carries `additionalProperties:
/// false` whether or not the operator declared it, so the closed-object rule is
/// applied once at the config edge. The result is a fresh `Map<String, dynamic>`
/// tree: [raw] may be an unmodifiable `YamlMap` with `dynamic` keys and is never
/// mutated or cast.
///
/// Throws [FormatException] naming [yamlPath], the offending keyword, and its
/// RFC 6901 pointer *within the schema document* — a different space from the
/// instance pointer an [OutputSchemaViolation] carries.
Map<String, dynamic> parseOutputSchema(Object? raw, {required String yamlPath}) =>
    _parse(raw, yamlPath, '', isRoot: true);

/// Validates [instance] against a schema produced by [parseOutputSchema].
///
/// Returns `null` when [instance] conforms, otherwise the first violation in a
/// depth-first walk driven by the schema: at each object level the checks run in
/// the order wrong-type, missing-required, unknown-property, then recursion into
/// `properties` in schema declaration order. Never throws and never reports more
/// than the first violation — a non-conforming result is failed, never repaired.
OutputSchemaViolation? validateOutputSchema(Object? instance, Map<String, dynamic> schema) =>
    _validate(instance, schema, '');

/// Renders [schema] as the output contract carried in a schema-bound agent's persona.
///
/// The text names every declared property and type, the top-level required set,
/// the closed-object rule, and the instruction to answer with only the JSON
/// value — no prose, no code fences.
String renderOutputSchemaContract(Map<String, dynamic> schema) {
  final required = (schema['required'] as List).cast<String>();
  return [
    '## Output Contract',
    '',
    'Respond with only the JSON value described by this schema. No prose before or after it, and no code fences.',
    '',
    const JsonEncoder.withIndent('  ').convert(schema),
    '',
    'Every object is closed (`additionalProperties: false`): a property not declared under its `properties` is '
        'rejected, as is a value of the wrong type or a missing required property.',
    'Required top-level properties: ${required.isEmpty ? 'none' : required.join(', ')}.',
    'A response that does not conform is rejected outright — it is not repaired, defaulted, or partially accepted.',
  ].join('\n');
}

Map<String, dynamic> _parse(Object? raw, String yamlPath, String pointer, {required bool isRoot}) {
  if (raw is! Map) {
    throw _reject(yamlPath, pointer, 'a schema must be a mapping');
  }
  if (raw.isEmpty) {
    throw _reject(yamlPath, pointer, 'a schema must not be empty');
  }

  final type = raw['type'];
  if (type is! String) {
    throw _reject(
      yamlPath,
      '$pointer/type',
      'every schema needs a single "type" name (one of ${_types.join(', ')}); '
          'a type list, a missing type, and YAML `type: null` are all rejected — write `type: "null"` for the null type',
    );
  }
  if (!_types.contains(type)) {
    throw _reject(yamlPath, '$pointer/type', 'unsupported type "$type"; accepted: ${_types.join(', ')}');
  }
  if (isRoot && type != 'object') {
    throw _reject(yamlPath, '$pointer/type', 'the root schema must be `type: object`');
  }

  final out = <String, dynamic>{'type': type};
  for (final key in raw.keys) {
    if (key is! String) {
      throw _reject(yamlPath, pointer, 'schema keys must be strings');
    }
    if (key == 'type' || _annotations.contains(key)) continue;
    if (!_supported.contains(key)) {
      throw _reject(
        yamlPath,
        '$pointer/${_escape(key)}',
        'unsupported keyword "$key"; supported: ${_supported.join(', ')} '
            '(plus the ignored annotations title, description, \$schema)',
      );
    }
    final validHere = switch (key) {
      'properties' || 'required' || 'additionalProperties' => type == 'object',
      'items' => type == 'array',
      'enum' => _scalarTypes.contains(type),
      _ => false,
    };
    if (!validHere) {
      throw _reject(yamlPath, '$pointer/$key', 'keyword "$key" is not valid under `type: $type`');
    }
  }

  switch (type) {
    case 'object':
      if (raw.containsKey('properties') && raw['properties'] == null) {
        throw _reject(yamlPath, '$pointer/properties', '"properties" must be a mapping of property name to schema');
      }
      if (raw.containsKey('required') && raw['required'] == null) {
        throw _reject(yamlPath, '$pointer/required', '"required" must be a list of property names');
      }
      out['properties'] = _parseProperties(raw['properties'], yamlPath, pointer);
      out['required'] = _parseRequired(raw['required'], out['properties'] as Map<String, dynamic>, yamlPath, pointer);
      final additional = raw['additionalProperties'];
      if (raw.containsKey('additionalProperties') && additional is! bool) {
        throw _reject(
          yamlPath,
          '$pointer/additionalProperties',
          'only a boolean is accepted here, and it is forced to false — a schema-valued '
              '"additionalProperties" would reopen the object',
        );
      }
      out['additionalProperties'] = false;
    case 'array':
      final items = raw['items'];
      if (items == null) {
        throw _reject(
          yamlPath,
          '$pointer/items',
          '`type: array` requires an "items" schema — without one nothing bounds the array\'s elements',
        );
      }
      if (items is List) {
        throw _reject(yamlPath, '$pointer/items', 'tuple-form "items" is not supported; declare a single schema');
      }
      out['items'] = _parse(items, yamlPath, '$pointer/items', isRoot: false);
    default:
      if (raw.containsKey('enum')) {
        out['enum'] = _parseEnum(raw['enum'], type, yamlPath, pointer);
      }
  }
  return out;
}

Map<String, dynamic> _parseProperties(Object? raw, String yamlPath, String pointer) {
  if (raw == null) return <String, dynamic>{};
  if (raw is! Map) {
    throw _reject(yamlPath, '$pointer/properties', '"properties" must be a mapping of property name to schema');
  }
  final properties = <String, dynamic>{};
  for (final entry in raw.entries) {
    final name = entry.key;
    if (name is! String) {
      throw _reject(yamlPath, '$pointer/properties', 'property names must be strings');
    }
    properties[name] = _parse(entry.value, yamlPath, '$pointer/properties/${_escape(name)}', isRoot: false);
  }
  return properties;
}

List<String> _parseRequired(Object? raw, Map<String, dynamic> properties, String yamlPath, String pointer) {
  if (raw == null) return const <String>[];
  if (raw is! List) {
    throw _reject(yamlPath, '$pointer/required', '"required" must be a list of property names');
  }
  final required = <String>[];
  for (final name in raw) {
    if (name is! String) {
      throw _reject(yamlPath, '$pointer/required', '"required" entries must be property names');
    }
    if (!properties.containsKey(name)) {
      throw _reject(
        yamlPath,
        '$pointer/required',
        'required property "$name" is not declared in "properties"; under the closed-object rule no instance could '
            'satisfy it',
      );
    }
    required.add(name);
  }
  return required;
}

List<Object?> _parseEnum(Object? raw, String type, String yamlPath, String pointer) {
  if (raw is! List) {
    throw _reject(yamlPath, '$pointer/enum', '"enum" must be a list of scalar values');
  }
  if (raw.isEmpty) {
    throw _reject(yamlPath, '$pointer/enum', '"enum" must not be empty — no value could satisfy it');
  }
  final members = <Object?>[];
  for (final member in raw) {
    if (member is Map || member is List) {
      throw _reject(yamlPath, '$pointer/enum', '"enum" members must be scalars');
    }
    if (!_matchesType(member, type)) {
      throw _reject(yamlPath, '$pointer/enum', 'an "enum" member cannot satisfy the declared `type: $type`');
    }
    members.add(member);
  }
  return members;
}

OutputSchemaViolation? _validate(Object? value, Map<String, dynamic> schema, String pointer) {
  final type = schema['type'] as String;
  switch (type) {
    case 'object':
      if (value is! Map) {
        return OutputSchemaViolation(pointer, 'expected an object, got ${_describe(value)}');
      }
      final properties = schema['properties'] as Map<String, dynamic>;
      for (final name in schema['required'] as List) {
        if (!value.containsKey(name)) {
          return OutputSchemaViolation('$pointer/${_escape(name as String)}', 'missing required property');
        }
      }
      for (final key in value.keys) {
        if (!properties.containsKey(key)) {
          return OutputSchemaViolation('$pointer/${_unknownPropertySegment('$key')}', 'unknown property');
        }
      }
      for (final entry in properties.entries) {
        if (!value.containsKey(entry.key)) continue;
        final violation = _validate(
          value[entry.key],
          entry.value as Map<String, dynamic>,
          '$pointer/${_escape(entry.key)}',
        );
        if (violation != null) return violation;
      }
      return null;
    case 'array':
      if (value is! List) {
        return OutputSchemaViolation(pointer, 'expected an array, got ${_describe(value)}');
      }
      final items = schema['items'] as Map<String, dynamic>;
      for (var i = 0; i < value.length; i++) {
        final violation = _validate(value[i], items, '$pointer/$i');
        if (violation != null) return violation;
      }
      return null;
    default:
      if (!_matchesType(value, type)) {
        return OutputSchemaViolation(pointer, 'expected $type, got ${_describe(value)}');
      }
      final members = schema['enum'] as List?;
      if (members != null && !members.any((m) => m.runtimeType == value.runtimeType && m == value)) {
        return OutputSchemaViolation(pointer, 'value is not one of the declared "enum" members');
      }
      return null;
  }
}

bool _matchesType(Object? value, String type) => switch (type) {
  'string' => value is String,
  'integer' => value is int,
  'number' => value is num,
  'boolean' => value is bool,
  'null' => value == null,
  'object' => value is Map,
  'array' => value is List,
  _ => false,
};

/// Names the runtime shape of [value] without quoting its content.
String _describe(Object? value) => switch (value) {
  null => 'null',
  String() => 'a string',
  int() => 'an integer',
  num() => 'a number',
  bool() => 'a boolean',
  List() => 'an array',
  Map() => 'an object',
  _ => 'an unsupported value',
};

String _escape(String segment) => segment.replaceAll('~', '~0').replaceAll('/', '~1');

String _unknownPropertySegment(String segment) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(segment)) {
    hash = ((hash ^ byte) * 0x100000001b3) & 0xffffffffffffffff;
  }
  return 'unknown-${hash.toRadixString(16).padLeft(16, '0')}';
}

FormatException _reject(String yamlPath, String pointer, String detail) => FormatException(
  '$yamlPath: $detail (at ${pointer.isEmpty ? 'the schema root' : '"$pointer"'} in the schema document).',
);
