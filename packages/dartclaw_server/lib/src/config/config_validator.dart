import 'config_meta.dart';

/// A validation error for a single config field.
class ValidationError {
  /// YAML path of the field that failed validation.
  final String field;

  /// Human-readable error message.
  final String message;

  const ValidationError({required this.field, required this.message});

  @override
  String toString() => 'ValidationError($field: $message)';
}

/// Stateless validator for config field updates.
///
/// Validates proposed values against the [ConfigMeta] registry:
/// unknown fields, read-only fields, type checks, and constraint checks.
class ConfigValidator {
  const ConfigValidator();

  /// Validates proposed config updates.
  ///
  /// [updates] maps dot-separated YAML paths to proposed values.
  /// Returns a list of validation errors (empty = all valid).
  ///
  /// Checks performed in order for each field:
  /// 1. Field is known (exists in [ConfigMeta])
  /// 2. Field is writable (not readonly)
  /// 3. Type check (int, string, bool, enum)
  /// 4. Constraint check (range, non-empty, allowed values)
  List<ValidationError> validate(Map<String, dynamic> updates) {
    final errors = <ValidationError>[];

    for (final entry in updates.entries) {
      final path = entry.key;
      final value = entry.value;

      // 1. Known field?
      if (!ConfigMeta.isKnown(path)) {
        errors.add(ValidationError(
          field: path,
          message: "Unknown config field: '$path'",
        ));
        continue;
      }

      final meta = ConfigMeta.fields[path]!;

      // 2. Writable?
      if (meta.mutability == ConfigMutability.readonly) {
        errors.add(ValidationError(
          field: path,
          message: "Field '$path' is read-only",
        ));
        continue;
      }

      // 3 & 4. Type + constraint checks
      final error = _validateValue(meta, value);
      if (error != null) errors.add(error);
    }

    return errors;
  }

  ValidationError? _validateValue(FieldMeta meta, Object? value) {
    // Null handling
    if (value == null) {
      if (meta.nullable) return null;
      return ValidationError(
        field: meta.yamlPath,
        message: "Field '${meta.yamlPath}' cannot be null",
      );
    }

    return switch (meta.type) {
      ConfigFieldType.int_ => _validateInt(meta, value),
      ConfigFieldType.string => _validateString(meta, value),
      ConfigFieldType.bool_ => _validateBool(meta, value),
      ConfigFieldType.enum_ => _validateEnum(meta, value),
    };
  }

  ValidationError? _validateInt(FieldMeta meta, Object value) {
    int intValue;

    if (value is int) {
      intValue = value;
    } else if (value is double) {
      if (value != value.toInt().toDouble()) {
        final typeLabel = meta.nullable ? 'an integer or null' : 'an integer';
        return ValidationError(
          field: meta.yamlPath,
          message:
              "Field '${meta.yamlPath}' must be $typeLabel, got ${value.runtimeType}",
        );
      }
      intValue = value.toInt();
    } else {
      final typeLabel = meta.nullable ? 'an integer or null' : 'an integer';
      return ValidationError(
        field: meta.yamlPath,
        message:
            "Field '${meta.yamlPath}' must be $typeLabel, got ${value.runtimeType}",
      );
    }

    // Range checks
    final min = meta.min;
    final max = meta.max;
    if (min != null && max != null && (intValue < min || intValue > max)) {
      return ValidationError(
        field: meta.yamlPath,
        message:
            "Field '${meta.yamlPath}' must be between $min and $max, got $intValue",
      );
    }
    if (min != null && max == null && intValue < min) {
      return ValidationError(
        field: meta.yamlPath,
        message:
            "Field '${meta.yamlPath}' must be >= $min, got $intValue",
      );
    }

    return null;
  }

  ValidationError? _validateString(FieldMeta meta, Object value) {
    if (value is! String) {
      final typeLabel = meta.nullable ? 'a string or null' : 'a string';
      return ValidationError(
        field: meta.yamlPath,
        message:
            "Field '${meta.yamlPath}' must be $typeLabel, got ${value.runtimeType}",
      );
    }

    // Non-empty check (non-nullable strings must not be blank)
    if (!meta.nullable && value.trim().isEmpty) {
      return ValidationError(
        field: meta.yamlPath,
        message: "Field '${meta.yamlPath}' must not be empty",
      );
    }

    return null;
  }

  ValidationError? _validateBool(FieldMeta meta, Object value) {
    if (value is! bool) {
      return ValidationError(
        field: meta.yamlPath,
        message:
            "Field '${meta.yamlPath}' must be a boolean, got ${value.runtimeType}",
      );
    }
    return null;
  }

  ValidationError? _validateEnum(FieldMeta meta, Object value) {
    if (value is! String) {
      return ValidationError(
        field: meta.yamlPath,
        message:
            "Field '${meta.yamlPath}' must be a string, got ${value.runtimeType}",
      );
    }

    final allowed = meta.allowedValues!;
    if (!allowed.contains(value)) {
      return ValidationError(
        field: meta.yamlPath,
        message:
            "Field '${meta.yamlPath}' must be one of: ${allowed.join(', ')} \u2014 got '$value'",
      );
    }

    return null;
  }
}
