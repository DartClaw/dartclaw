/// A reader of exactly the keyword set `ConfigMeta.toJsonSchema()` emits.
///
/// Complete rather than partial: the emitted vocabulary is closed and asserted
/// closed, so every keyword an artifact can carry is handled here. A keyword
/// outside the set is a schema defect, not something to skip over.
///
/// `dev/tools/render_config_reference.dart#_collectFields` descends the same
/// schema and is deliberately **not** shared with this one. It answers a
/// different question — schema to dotted leaf keys, with no instance in hand —
/// and it stops at an array rather than descending `items`, because the
/// operator reference documents the key and describes the element shape in
/// prose. Validation cannot stop there: array indices and `additionalProperties`
/// keys exist only in the instance, so this walk is instance-driven by
/// necessity. Collapsing them would mean one of the two answering a question it
/// was not asked.
library;

/// Every keyword the emitter may use. A schema position carrying anything else
/// is a defect: this reader would silently ignore it.
const Set<String> emittedKeywords = {
  r'$schema',
  'title',
  'description',
  'type',
  'properties',
  'additionalProperties',
  'items',
  'enum',
  'minimum',
  'maximum',
};

/// Every `type` name the emitter may use.
const Set<String> emittedTypes = {'array', 'boolean', 'integer', 'null', 'number', 'object', 'string'};

/// Validates [instance] against [schema], returning one diagnostic per
/// violation, each naming the instance path it was found at.
List<String> validateAgainstSchema(Object? instance, Map<String, Object?> schema, {String path = ''}) {
  final diagnostics = <String>[];
  final label = path.isEmpty ? '<root>' : path;

  if (schema['type'] case final declared?) {
    final accepted = declared is List ? declared.cast<String>() : [declared as String];
    if (!accepted.any((type) => _isOfType(instance, type))) {
      diagnostics.add('$label: expected ${accepted.join(' or ')}, found ${_typeName(instance)}');
      // A wrong type makes every deeper check meaningless noise.
      return diagnostics;
    }
  }

  if (schema['enum'] case final List<Object?> allowed) {
    if (!allowed.contains(instance)) {
      diagnostics.add('$label: $instance is not one of ${allowed.join(', ')}');
    }
  }

  if (instance is int && instance is! bool) {
    if (schema['minimum'] case final int min when instance < min) {
      diagnostics.add('$label: $instance is below the minimum $min');
    }
    if (schema['maximum'] case final int max when instance > max) {
      diagnostics.add('$label: $instance is above the maximum $max');
    }
  }

  if (instance is Map) {
    final properties = (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
    final additional = schema['additionalProperties'];
    for (final entry in instance.entries) {
      final key = entry.key.toString();
      final child = '${path.isEmpty ? '' : '$path.'}$key';
      if (properties[key] case final Map<String, Object?> propertySchema) {
        diagnostics.addAll(validateAgainstSchema(entry.value, propertySchema, path: child));
      } else if (additional is Map<String, Object?>) {
        diagnostics.addAll(validateAgainstSchema(entry.value, additional, path: child));
      } else if (additional == false) {
        diagnostics.add('$child: unknown property "$key"');
      }
    }
  }

  // Without this arm every list-valued field is unreachable and the gate is
  // green because it never looked inside one.
  if (instance is List) {
    if (schema['items'] case final Map<String, Object?> items) {
      for (var index = 0; index < instance.length; index++) {
        diagnostics.addAll(validateAgainstSchema(instance[index], items, path: '$path[$index]'));
      }
    }
  }

  return diagnostics;
}

bool _isOfType(Object? value, String type) => switch (type) {
  'integer' => value is int,
  'string' => value is String,
  'boolean' => value is bool,
  'array' => value is List,
  'object' => value is Map,
  'null' => value == null,
  _ => false,
};

String _typeName(Object? value) => switch (value) {
  null => 'null',
  bool() => 'boolean',
  int() => 'integer',
  double() => 'number',
  List() => 'array',
  Map() => 'object',
  _ => 'string',
};

/// Every schema position in [schema]: the schema itself, each `properties`
/// value, `items`, and a schema-valued `additionalProperties`.
///
/// Positions rather than key names, because real config keys are called
/// `default`, `title`, `description` and `type` — a name-based scan reds a
/// correct artifact.
Iterable<Map<String, Object?>> schemaPositions(Map<String, Object?> schema) sync* {
  yield schema;
  for (final property in ((schema['properties'] as Map?) ?? const {}).values) {
    yield* schemaPositions((property as Map).cast<String, Object?>());
  }
  if (schema['items'] case final Map<String, Object?> items) {
    yield* schemaPositions(items);
  }
  if (schema['additionalProperties'] case final Map<String, Object?> additional) {
    yield* schemaPositions(additional);
  }
}
