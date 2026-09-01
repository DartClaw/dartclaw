import 'config_meta.dart';

/// One way in which a value fails the [FieldMeta] declaration it was checked
/// against.
///
/// Carries no operator-facing text: the decision is shared, the wording is
/// not. A refusing consumer renders its own sentence; a warn-and-default
/// consumer renders its own advisory, from the same verdict.
sealed class FieldConstraintViolation {
  /// The declaration the value was checked against.
  final FieldMeta field;

  /// The value the check judged.
  final Object? value;

  /// Creates a [FieldConstraintViolation] value.
  const new({required this.field, required this.value});
}

/// `null` was supplied for a field that does not declare itself nullable.
final class NullNotAllowed extends FieldConstraintViolation {
  /// Creates a [NullNotAllowed] value.
  const new({required super.field}) : super(value: null);
}

/// The value's runtime type does not satisfy the declared
/// [FieldMeta.type].
final class TypeMismatch extends FieldConstraintViolation {
  /// Creates a [TypeMismatch] value.
  const new({required super.field, required super.value});
}

/// A number fell outside the declared [FieldMeta.min] / [FieldMeta.max].
///
/// [value] is the value the range was applied to. An [ConfigFieldType.int_]
/// field judges — and reports — a whole-number double as its `int` (`70000.0`
/// violates as `70000`); a [ConfigFieldType.double_] field keeps the fraction.
final class OutOfRange extends FieldConstraintViolation {
  /// Creates an [OutOfRange] value.
  const new({required super.field, required num super.value});
}

/// A non-nullable string field was given a blank or whitespace-only value.
final class BlankString extends FieldConstraintViolation {
  /// Creates a [BlankString] value.
  const new({required super.field, required String super.value});
}

/// The value is not a member of the declared [FieldMeta.allowedValues].
final class ValueNotAllowed extends FieldConstraintViolation {
  /// Creates a [ValueNotAllowed] value.
  const new({required super.field, required String super.value});
}

/// A collection carried an element of the wrong type for the declared
/// [FieldMeta.type].
///
/// [value] is the whole collection, matching what the caller supplied.
final class ElementTypeMismatch extends FieldConstraintViolation {
  /// Creates an [ElementTypeMismatch] value.
  const new({required super.field, required super.value});
}

/// The single decision procedure for "does this value satisfy this field's
/// declaration".
///
/// Every bound it applies is read off the [FieldMeta] it is handed, so the
/// config API, the settings UI and the parse sites cannot drift apart by
/// keeping second copies of a range, a type or an allowed set.
abstract final class FieldConstraints {
  /// Evaluates [value] against [field], returning `null` when it satisfies the
  /// declaration and otherwise the first violation that decided the refusal.
  ///
  /// Nullability is decided ahead of the type switch, so `null` on a
  /// non-nullable field is always [NullNotAllowed] rather than a
  /// [TypeMismatch]. Whole-number doubles satisfy [ConfigFieldType.int_]
  /// (`3000.0` passes, `3000.5` and a non-finite double do not), because JSON
  /// decoders emit doubles for whole numbers.
  ///
  /// [FieldMeta.allowedValues] is honoured only for [ConfigFieldType.enum_];
  /// see `configuration-architecture.md` § 4 for the four string-typed
  /// declarations this deliberately leaves to their loaders. Throws a
  /// [TypeError] on an [ConfigFieldType.enum_] declaration carrying no
  /// [FieldMeta.allowedValues] — a malformed registry entry, pinned against by
  /// `config_meta_test.dart` rather than silently accepted.
  ///
  /// A caller that echoes the operator's input should echo what it passed in
  /// rather than [OutOfRange.value], which is the numeric value the range was
  /// judged on.
  static FieldConstraintViolation? evaluate(FieldMeta field, Object? value) {
    if (value == null) {
      return field.nullable ? null : NullNotAllowed(field: field);
    }

    final primary = _evaluateType(field, value, field.type);
    final alternative = field.alsoAccepts;
    if (primary is! TypeMismatch || alternative == null) return primary;
    return _evaluateType(field, value, alternative);
  }

  static FieldConstraintViolation? _evaluateType(FieldMeta field, Object value, ConfigFieldType type) => switch (type) {
    ConfigFieldType.int_ => _evaluateInt(field, value),
    ConfigFieldType.double_ => _evaluateDouble(field, value),
    ConfigFieldType.string => _evaluateString(field, value),
    ConfigFieldType.bool_ => value is bool ? null : TypeMismatch(field: field, value: value),
    ConfigFieldType.enum_ => _evaluateEnum(field, value),
    ConfigFieldType.stringList => _evaluateElements(field, value, (item) => item is String),
    ConfigFieldType.objectList => _evaluateElements(field, value, (item) => item is Map),
    ConfigFieldType.objectMap => value is Map ? null : TypeMismatch(field: field, value: value),
  };

  static FieldConstraintViolation? _evaluateInt(FieldMeta field, Object value) {
    final int intValue;
    if (value is int) {
      intValue = value;
    } else if (value is double && value.isFinite && value == value.toInt().toDouble()) {
      intValue = value.toInt();
    } else {
      return TypeMismatch(field: field, value: value);
    }

    final min = field.min;
    final max = field.max;
    if (min != null && intValue < min) return OutOfRange(field: field, value: intValue);
    if (max != null && intValue > max) return OutOfRange(field: field, value: intValue);
    return null;
  }

  static FieldConstraintViolation? _evaluateDouble(FieldMeta field, Object value) {
    if (value is! num) return TypeMismatch(field: field, value: value);

    final min = field.min;
    final max = field.max;
    if (min != null && value < min) return OutOfRange(field: field, value: value);
    if (max != null && value > max) return OutOfRange(field: field, value: value);
    return null;
  }

  static FieldConstraintViolation? _evaluateString(FieldMeta field, Object value) {
    if (value is! String) return TypeMismatch(field: field, value: value);
    if (!field.nullable && value.trim().isEmpty) return BlankString(field: field, value: value);
    return null;
  }

  static FieldConstraintViolation? _evaluateEnum(FieldMeta field, Object value) {
    if (value is! String) return TypeMismatch(field: field, value: value);
    if (!field.allowedValues!.contains(value)) return ValueNotAllowed(field: field, value: value);
    return null;
  }

  static FieldConstraintViolation? _evaluateElements(
    FieldMeta field,
    Object value,
    bool Function(Object? item) isWellTyped,
  ) {
    if (value is! List) return TypeMismatch(field: field, value: value);
    if (value.any((item) => !isWellTyped(item))) return ElementTypeMismatch(field: field, value: value);
    return null;
  }
}
