import 'config_constraints.dart';
import 'config_meta.dart';
import 'governance_config.dart' show TurnLimitsConfig;
import 'turn_limits_validation.dart';

/// The refusal for a path [ConfigMeta] does not describe.
///
/// The YAML load sweep and [ConfigValidator] must refuse an unknown path in the
/// same words, so this is the only place the sentence is written.
String unknownConfigFieldMessage(String path) => "Unknown config field: '$path'";

/// A validation error for a single config field.
class ValidationError {
  /// YAML path of the field that failed validation.
  final String field;

  /// Human-readable error message.
  final String message;

  /// const ValidationError({required this.field, required this.me.
  const new({required this.field, required this.message});

  @override
  String toString() => 'ValidationError($field: $message)';
}

/// Stateless validator for config field updates.
///
/// Gates a proposed write on the [ConfigMeta] registry — unknown field, then
/// read-only field — and then renders [FieldConstraints]' verdict as an
/// operator-facing sentence. Per-field bounds are decided there, not here, so
/// this class holds no copy of a range, a type or an allowed set.
class ConfigValidator {
  /// const ConfigValidator();.
  const new();

  /// Validates proposed config updates.
  ///
  /// [updates] maps dot-separated YAML paths to proposed values.
  /// Returns a list of validation errors (empty = all valid).
  ///
  /// Checks performed in order for each field:
  /// 1. Field is known (exists in [ConfigMeta])
  /// 2. Field is writable (not readonly)
  /// 3. The field's declaration, via [FieldConstraints.evaluate]
  List<ValidationError> validate(Map<String, dynamic> updates, {Map<String, dynamic> currentValues = const {}}) {
    final errors = <ValidationError>[];

    for (final entry in updates.entries) {
      final path = entry.key;
      final value = entry.value;

      // 1. Known field?
      if (!ConfigMeta.isKnown(path)) {
        errors.add(ValidationError(field: path, message: unknownConfigFieldMessage(path)));
        continue;
      }

      final meta = ConfigMeta.fields[path]!;

      // 2. Writable?
      if (meta.mutability == ConfigMutability.readonly) {
        errors.add(ValidationError(field: path, message: "Field '$path' is read-only"));
        continue;
      }

      // 3. Declared constraints
      final error = _validateValue(meta, value);
      if (error != null) {
        errors.add(error);
        continue;
      }

      // 4. Declared entry shape, for the object-valued sections
      errors.addAll(_validateEntries(meta, value));
    }

    _validateGoogleChatRequirements(updates, currentValues, errors);
    _validateGitHubRequirements(updates, currentValues, errors);
    _validateSpaceEventsRequirements(updates, currentValues, errors);
    _validateExecutionMode(updates, currentValues, errors);
    _validateTurnLimits(updates, currentValues, errors);
    return errors;
  }

  void _validateTurnLimits(
    Map<String, dynamic> updates,
    Map<String, dynamic> currentValues,
    List<ValidationError> errors,
  ) {
    const stallField = 'governance.turn_limits.stall_timeout';
    const turnField = 'governance.turn_limits.turn_timeout';
    if (!updates.containsKey(stallField) && !updates.containsKey(turnField)) return;
    if (errors.any((error) => error.field == stallField || error.field == turnField)) return;

    const defaults = TurnLimitsConfig.defaults();
    final validated = validateTurnLimitDurations(
      stallTimeout: updates.containsKey(stallField) ? updates[stallField] : currentValues[stallField],
      turnTimeout: updates.containsKey(turnField) ? updates[turnField] : currentValues[turnField],
      fallbackStallTimeout: defaults.stallTimeout,
      fallbackTurnTimeout: defaults.turnTimeout,
    );
    if (validated.errorMessage case final message?) {
      errors.add(ValidationError(field: validated.errorField!, message: message));
    }
  }

  /// Rejects a container execution selection that no enabled container runtime
  /// can satisfy.
  ///
  /// Restart-tier, so the write would otherwise be accepted here and only fail
  /// at the next boot; substituting host execution is forbidden, so the
  /// unsatisfiable value is refused at write time instead.
  void _validateExecutionMode(
    Map<String, dynamic> updates,
    Map<String, dynamic> currentValues,
    List<ValidationError> errors,
  ) {
    if (!updates.containsKey('agent.execution')) return;
    if (updates['agent.execution'] != 'container') return;
    if (_mergedValue<bool>('container.enabled', updates, currentValues) == true) return;
    errors.add(
      const ValidationError(
        field: 'agent.execution',
        message:
            "Field 'agent.execution' cannot be 'container' while container isolation is disabled. "
            "Enable container.enabled first, or select 'host'.",
      ),
    );
  }

  void _validateGoogleChatRequirements(
    Map<String, dynamic> updates,
    Map<String, dynamic> currentValues,
    List<ValidationError> errors,
  ) {
    final enabled = _mergedValue<bool>('channels.google_chat.enabled', updates, currentValues);
    if (enabled != true) {
      return;
    }

    _requireNonBlankString(
      field: 'channels.google_chat.service_account',
      updates: updates,
      currentValues: currentValues,
      errors: errors,
    );
    _requireNonBlankString(
      field: 'channels.google_chat.audience.type',
      updates: updates,
      currentValues: currentValues,
      errors: errors,
    );
    _requireNonBlankString(
      field: 'channels.google_chat.audience.value',
      updates: updates,
      currentValues: currentValues,
      errors: errors,
    );
  }

  void _validateGitHubRequirements(
    Map<String, dynamic> updates,
    Map<String, dynamic> currentValues,
    List<ValidationError> errors,
  ) {
    final enabled = _mergedValue<bool>('github.enabled', updates, currentValues);
    if (enabled == true) {
      _requireNonBlankString(
        field: 'github.webhook_secret',
        updates: updates,
        currentValues: currentValues,
        errors: errors,
        requiredByField: 'github.enabled',
      );
    }

    // The per-trigger field checks that used to live here are gone: the
    // registry declares `github.triggers`' entry shape, and the single
    // validation pass now judges every entry against it. Keeping both meant two
    // answers — and the local one refused a config the loader accepts, since
    // `event` and `workflow` default when omitted.
  }

  void _validateSpaceEventsRequirements(
    Map<String, dynamic> updates,
    Map<String, dynamic> currentValues,
    List<ValidationError> errors,
  ) {
    final enabled = _mergedValue<bool>('channels.google_chat.space_events.enabled', updates, currentValues);
    if (enabled != true) return;

    _requireNonBlankString(
      field: 'channels.google_chat.pubsub.project_id',
      updates: updates,
      currentValues: currentValues,
      errors: errors,
      requiredByField: 'channels.google_chat.space_events.enabled',
    );
    _requireNonBlankString(
      field: 'channels.google_chat.pubsub.subscription',
      updates: updates,
      currentValues: currentValues,
      errors: errors,
      requiredByField: 'channels.google_chat.space_events.enabled',
    );
    _requireNonBlankString(
      field: 'channels.google_chat.space_events.pubsub_topic',
      updates: updates,
      currentValues: currentValues,
      errors: errors,
      requiredByField: 'channels.google_chat.space_events.enabled',
    );
  }

  T? _mergedValue<T>(String field, Map<String, dynamic> updates, Map<String, dynamic> currentValues) {
    final source = updates.containsKey(field) ? updates : currentValues;
    final value = source[field];
    return value is T ? value : null;
  }

  void _requireNonBlankString({
    required String field,
    required Map<String, dynamic> updates,
    required Map<String, dynamic> currentValues,
    required List<ValidationError> errors,
    String requiredByField = 'channels.google_chat.enabled',
  }) {
    final source = updates.containsKey(field) ? updates : currentValues;
    final value = source[field];
    if (value is String && value.trim().isNotEmpty) {
      return;
    }
    if (errors.any((error) => error.field == field)) {
      return;
    }
    errors.add(ValidationError(field: field, message: "Field '$field' is required when $requiredByField is true"));
  }

  /// Checks each entry of an object-valued field against the shape the registry
  /// declares for it, reusing the one constraint evaluator.
  ///
  /// Only declared keys are judged. An entry shape does not say whether an entry
  /// is closed, and several are open on purpose — `ProviderEntry.options`
  /// absorbs unnamed `providers.<id>` keys, and `dartclaw init` writes some
  /// itself — so refusing an undeclared key would refuse a config DartClaw
  /// wrote. What this closes is the other half: a *declared* per-entry key that
  /// decides placement or posture used to reach the runtime through a map
  /// nothing inspected, and was caught at the next boot if at all.
  List<ValidationError> _validateEntries(FieldMeta meta, Object? value) {
    final shape = meta.entry;
    if (shape == null || value == null) return const [];
    return switch (value) {
      Map<Object?, Object?>() => [
        for (final entry in value.entries) ..._validateEntry(shape, entry.value, '${meta.yamlPath}.${entry.key}'),
      ],
      List<Object?>() => [
        for (final (index, element) in value.indexed) ..._validateEntry(shape, element, '${meta.yamlPath}[$index]'),
      ],
      _ => const [],
    };
  }

  List<ValidationError> _validateEntry(ConfigEntryShape shape, Object? entry, String path) {
    switch (shape) {
      case OpaqueEntry():
        return const [];
      case ValueEntry(:final value):
        final error = _validateValue(_asFieldMeta(value, path), entry);
        return error == null ? const [] : [error];
      case ObjectEntry(:final fields):
        if (entry is! Map) {
          return [ValidationError(field: path, message: "Entry '$path' must be an object")];
        }
        final errors = <ValidationError>[];
        for (final MapEntry(key: name, value: declared) in fields.entries) {
          if (!entry.containsKey(name)) continue;
          final fieldPath = '$path.$name';
          final error = _validateValue(_asFieldMeta(declared, fieldPath), entry[name]);
          if (error != null) {
            errors.add(error);
            continue;
          }
          final nested = declared.entry;
          if (nested != null) {
            errors.addAll(_validateEntry(nested, entry[name], fieldPath));
          }
        }
        return errors;
    }
  }

  /// Adapts an entry field to the shape [FieldConstraints] evaluates.
  ///
  /// [EntryFieldMeta] deliberately carries no mutability or JSON key — an entry
  /// is replaced through its container, so the container's govern — and those
  /// two are the only fields the evaluator does not read.
  FieldMeta _asFieldMeta(EntryFieldMeta field, String path) => FieldMeta(
    yamlPath: path,
    jsonKey: path,
    type: field.type,
    mutability: ConfigMutability.live,
    description: field.description,
    alsoAccepts: field.alsoAccepts,
    nullable: field.nullable,
    min: field.min,
    max: field.max,
    allowedValues: field.allowedValues,
    entry: field.entry,
  );

  ValidationError? _validateValue(FieldMeta meta, Object? value) {
    final violation = FieldConstraints.evaluate(meta, value);
    if (violation == null) return null;
    return ValidationError(field: meta.yamlPath, message: _messageFor(violation));
  }

  String _messageFor(FieldConstraintViolation violation) {
    final meta = violation.field;
    final path = meta.yamlPath;
    return switch (violation) {
      NullNotAllowed() => "Field '$path' cannot be null",
      TypeMismatch() => "Field '$path' must be ${_typeLabel(meta)}, got ${violation.value.runtimeType}",
      OutOfRange() => "Field '$path' ${_rangeClause(meta)}, got ${violation.value}",
      BlankString() => "Field '$path' must not be empty",
      ValueNotAllowed() =>
        "Field '$path' must be one of: ${meta.allowedValues!.join(', ')} \u2014 got '${violation.value}'",
      ElementTypeMismatch() => "Field '$path' must contain only ${_elementLabel(meta)}",
    };
  }

  String _typeLabel(FieldMeta meta) => switch (meta.type) {
    ConfigFieldType.int_ => meta.nullable ? 'an integer or null' : 'an integer',
    ConfigFieldType.double_ => meta.nullable ? 'a number or null' : 'a number',
    ConfigFieldType.string => meta.nullable ? 'a string or null' : 'a string',
    ConfigFieldType.bool_ => 'a boolean',
    ConfigFieldType.enum_ => 'a string',
    ConfigFieldType.stringList => 'a list of strings',
    ConfigFieldType.objectList => 'a list of objects',
    ConfigFieldType.objectMap => 'an object map',
  };

  String _elementLabel(FieldMeta meta) => meta.type == ConfigFieldType.stringList ? 'strings' : 'objects';

  String _rangeClause(FieldMeta meta) {
    final min = meta.min;
    final max = meta.max;
    if (min != null && max != null) return 'must be between $min and $max';
    if (min != null) return 'must be >= $min';
    return 'must be <= $max';
  }
}
