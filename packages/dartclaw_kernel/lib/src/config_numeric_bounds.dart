import 'config_constraints.dart';
import 'config_meta.dart';

/// Resolves integer bounds for config loaders without owning bound values.
abstract final class ConfigNumericBounds {
  /// Evaluates [value] against the registered [path].
  ///
  /// Throws [StateError] when the path or a required bound is absent.
  static FieldConstraintViolation? evaluate(
    String path,
    Object? value, {
    bool requireMin = false,
    bool requireMax = false,
  }) {
    final field = _field(path, requireMin: requireMin, requireMax: requireMax);
    return FieldConstraints.evaluate(field, value);
  }

  static FieldMeta _field(String path, {bool requireMin = false, bool requireMax = false}) {
    final field = ConfigMeta.fields[path];
    if (field == null) throw StateError('Numeric config field is not registered: $path');
    if (field.type != ConfigFieldType.int_) throw StateError('Numeric config field is not integer-typed: $path');
    if (requireMin && field.min == null) throw StateError('Numeric config field has no minimum: $path');
    if (requireMax && field.max == null) throw StateError('Numeric config field has no maximum: $path');
    return field;
  }

  /// Whether [value] violates the registered range for [path].
  static bool isOutOfRange(String path, int value, {bool requireMin = false, bool requireMax = false}) {
    final violation = evaluate(path, value, requireMin: requireMin, requireMax: requireMax);
    if (violation == null) return false;
    if (violation is OutOfRange) return true;
    throw StateError('Numeric config field produced ${violation.runtimeType}: $path');
  }

  /// Saturates [value] to both registered bounds for [path].
  static int clamp(String path, int value) {
    final field = _field(path, requireMin: true, requireMax: true);
    final violation = FieldConstraints.evaluate(field, value);
    if (violation == null) return value;
    if (violation is! OutOfRange) throw StateError('Numeric config field produced ${violation.runtimeType}: $path');
    return value.clamp(field.min!, field.max!);
  }
}
