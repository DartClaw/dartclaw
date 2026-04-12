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
    final expectedType = schema['type'] as String?;
    if (expectedType == null) return;

    switch (expectedType) {
      case 'object':
        if (value is! Map) {
          warnings.add('${_at(path)}Expected object, got ${value.runtimeType}');
          return;
        }
        _validateObject(value.cast<String, dynamic>(), schema, path, warnings);
      case 'array':
        if (value is! List) {
          warnings.add('${_at(path)}Expected array, got ${value.runtimeType}');
          return;
        }
        _validateArray(value, schema, path, warnings);
      case 'string':
        if (value is! String) {
          warnings.add('${_at(path)}Expected string, got ${value.runtimeType}');
        }
      case 'integer':
        if (value is! int && !(value is double && value == value.toInt())) {
          warnings.add('${_at(path)}Expected integer, got ${value.runtimeType}');
        }
      case 'number':
        if (value is! num) {
          warnings.add('${_at(path)}Expected number, got ${value.runtimeType}');
        }
      case 'boolean':
        if (value is! bool) {
          warnings.add('${_at(path)}Expected boolean, got ${value.runtimeType}');
        }
    }
  }

  void _validateObject(Map<String, dynamic> value, Map<String, dynamic> schema, String path, List<String> warnings) {
    final required = (schema['required'] as List?)?.cast<String>() ?? [];
    for (final field in required) {
      if (!value.containsKey(field)) {
        warnings.add('${_at(path)}Missing required field "$field"');
      }
    }

    final properties = schema['properties'] as Map<String, dynamic>?;
    if (properties == null) return;
    for (final entry in properties.entries) {
      final fieldValue = value[entry.key];
      if (fieldValue == null) continue; // Missing optional fields are fine.
      _validateValue(
        fieldValue,
        entry.value as Map<String, dynamic>,
        path.isEmpty ? entry.key : '$path.${entry.key}',
        warnings,
      );
    }
  }

  void _validateArray(List<dynamic> value, Map<String, dynamic> schema, String path, List<String> warnings) {
    final items = schema['items'] as Map<String, dynamic>?;
    if (items == null) return;
    for (var i = 0; i < value.length; i++) {
      _validateValue(value[i], items, '$path[$i]', warnings);
    }
  }

  String _at(String path) => path.isEmpty ? '' : 'At $path: ';
}
