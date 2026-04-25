/// Soft-validates parsed JSON against a schema definition.
///
/// Returns a list of warning strings. Empty list means valid.
/// Does NOT throw — all mismatches are warnings, not errors.
class SchemaValidator {
  const SchemaValidator();

  /// Validates [value] against [schema].
  ///
  /// [schema] is a JSON Schema-like Map with `type`, `required`, `properties`.
  List<String> validate(Object value, Map<String, dynamic> schema) {
    final warnings = <String>[];
    _validateValue(value, schema, '', warnings);
    return warnings;
  }

  void _validateValue(Object? value, Map<String, dynamic> schema, String path, List<String> warnings) {
    final rawType = schema['type'];
    final expectedTypes = switch (rawType) {
      final String type => <String>[type],
      final List<dynamic> types => types.whereType<String>().toList(growable: false),
      _ => const <String>[],
    };

    if (expectedTypes.isEmpty) {
      // No type constraint — still check enum.
      _validateEnum(value, schema, path, warnings);
      return;
    }

    if (value == null) {
      if (expectedTypes.contains('null')) return;
      warnings.add('${_at(path)}Expected ${expectedTypes.join(' or ')}, got null');
      return;
    }

    if (expectedTypes.contains('object')) {
      if (value is! Map) {
        warnings.add('${_at(path)}Expected object, got ${value.runtimeType}');
        return;
      }
      _validateObject(value.cast<String, dynamic>(), schema, path, warnings);
      return;
    }
    if (expectedTypes.contains('array')) {
      if (value is! List) {
        warnings.add('${_at(path)}Expected array, got ${value.runtimeType}');
        return;
      }
      _validateArray(value, schema, path, warnings);
      return;
    }
    if (expectedTypes.contains('string') && value is String) {
      _validateEnum(value, schema, path, warnings);
      return;
    }
    if (expectedTypes.contains('integer') && (value is int || (value is double && value == value.toInt()))) {
      _validateEnum(value, schema, path, warnings);
      _validateNumericBounds(value as num, schema, path, warnings);
      return;
    }
    if (expectedTypes.contains('number') && value is num) {
      _validateEnum(value, schema, path, warnings);
      _validateNumericBounds(value, schema, path, warnings);
      return;
    }
    if (expectedTypes.contains('boolean') && value is bool) {
      return;
    }

    warnings.add('${_at(path)}Expected ${expectedTypes.join(' or ')}, got ${value.runtimeType}');
  }

  void _validateObject(Map<String, dynamic> value, Map<String, dynamic> schema, String path, List<String> warnings) {
    final required = (schema['required'] as List?)?.cast<String>() ?? [];
    for (final field in required) {
      if (!value.containsKey(field)) {
        warnings.add('${_at(path)}Missing required field "$field"');
      }
    }

    final properties = schema['properties'] as Map<String, dynamic>?;
    if (properties != null) {
      for (final entry in properties.entries) {
        if (!value.containsKey(entry.key)) continue; // Truly missing — skip.
        final fieldValue = value[entry.key];
        _validateValue(
          fieldValue,
          entry.value as Map<String, dynamic>,
          path.isEmpty ? entry.key : '$path.${entry.key}',
          warnings,
        );
      }
    }

    _validateAdditionalProperties(value, schema, path, warnings);
  }

  void _validateAdditionalProperties(
    Map<String, dynamic> value,
    Map<String, dynamic> schema,
    String path,
    List<String> warnings,
  ) {
    final additionalProperties = schema['additionalProperties'];
    if (additionalProperties == false) {
      final properties = schema['properties'] as Map<String, dynamic>? ?? {};
      for (final key in value.keys) {
        if (!properties.containsKey(key)) {
          warnings.add('${_at(path)}Unexpected property "$key"');
        }
      }
    }
  }

  void _validateArray(List<dynamic> value, Map<String, dynamic> schema, String path, List<String> warnings) {
    final items = schema['items'] as Map<String, dynamic>?;
    if (items == null) return;
    for (var i = 0; i < value.length; i++) {
      _validateValue(value[i], items, '$path[$i]', warnings);
    }
  }

  void _validateEnum(Object? value, Map<String, dynamic> schema, String path, List<String> warnings) {
    final enumValues = schema['enum'] as List?;
    if (enumValues == null) return;
    if (!enumValues.contains(value)) {
      warnings.add('${_at(path)}Value ${_quote(value)} is not one of: ${enumValues.map(_quote).join(', ')}');
    }
  }

  void _validateNumericBounds(num value, Map<String, dynamic> schema, String path, List<String> warnings) {
    final minimum = schema['minimum'];
    final maximum = schema['maximum'];
    if (minimum is num && value < minimum) {
      warnings.add('${_at(path)}Value $value is less than minimum $minimum');
    }
    if (maximum is num && value > maximum) {
      warnings.add('${_at(path)}Value $value is greater than maximum $maximum');
    }
  }

  String _at(String path) => path.isEmpty ? '' : 'At $path: ';

  String _quote(Object? v) => v is String ? '"$v"' : '$v';
}
