import 'package:dartclaw_kernel/dartclaw_kernel.dart';

enum SettingsControlKind { text, number, textarea, select, toggle, list, fact, entries }

/// A field's current value, or the fact that it has none.
class ResolvedFieldValue {
  const new({required this.value, required this.isSet});
  final Object? value;
  final bool isSet;
  static const absent = ResolvedFieldValue(value: null, isSet: false);
}

/// Registered paths whose value must never reach the page.
///
/// `gateway.token` and `github.webhook_secret` are already masked by
/// `ConfigSerializer`; naming them here means the YAML fallback cannot undo
/// that, and `credentials` — which the serializer does not emit at all — is
/// covered by the same rule rather than by a second one. The Google Chat
/// service account may hold inline JSON rather than only a path, so its
/// read-only presentation follows the same fail-closed rule.
const settingsMaskedFields = {
  'credentials',
  'gateway.token',
  'github.webhook_secret',
  'channels.google_chat.service_account',
};

const _longTextFields = {'context.compact_instructions', 'context.identifier_instructions'};

const _inheritedFieldSources = <String, List<String>>{
  'workflow.defaults.workflow.provider': ['agent.provider'],
  'workflow.defaults.workflow.model': ['agent.model'],
  'workflow.defaults.planner.provider': ['workflow.defaults.workflow.provider', 'agent.provider'],
  'workflow.defaults.planner.model': ['workflow.defaults.workflow.model', 'agent.model'],
  'workflow.defaults.executor.provider': ['workflow.defaults.workflow.provider', 'agent.provider'],
  'workflow.defaults.executor.model': ['workflow.defaults.workflow.model', 'agent.model'],
  'workflow.defaults.reviewer.provider': ['workflow.defaults.workflow.provider', 'agent.provider'],
  'workflow.defaults.reviewer.model': ['workflow.defaults.workflow.model', 'agent.model'],
};

class SettingsValueResolver {
  const new({required Map<String, dynamic> serialized, required Map<String, dynamic> yaml})
    : _serialized = serialized,
      _yaml = yaml;

  final Map<String, dynamic> _serialized;
  final Map<String, dynamic> _yaml;

  ResolvedFieldValue resolve(FieldMeta meta) {
    if (settingsMaskedFields.contains(meta.yamlPath)) {
      final serialized = _lookup(_serialized, meta.jsonKey);
      final persisted = _lookup(_yaml, meta.yamlPath);
      final present = _hasConfiguredValue(serialized) || _hasConfiguredValue(persisted);
      return ResolvedFieldValue(value: null, isSet: present);
    }
    final serialized = _lookup(_serialized, meta.jsonKey);
    if (serialized.isSet && _matchesFieldType(serialized.value, meta.type)) return serialized;
    return _lookup(_yaml, meta.yamlPath);
  }

  String? inheritedValueFor(String yamlPath) {
    for (final source in _inheritedFieldSources[yamlPath] ?? const <String>[]) {
      final meta = ConfigMeta.fields[source];
      if (meta == null) continue;
      final resolved = resolve(meta);
      final value = resolved.value;
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  static bool inherits(String yamlPath) => _inheritedFieldSources.containsKey(yamlPath);

  static ResolvedFieldValue _lookup(Map<String, dynamic> tree, String dottedPath) {
    Object? current = tree;
    for (final segment in dottedPath.split('.')) {
      if (current is! Map) return ResolvedFieldValue.absent;
      if (!current.containsKey(segment)) return ResolvedFieldValue.absent;
      current = current[segment];
    }
    return ResolvedFieldValue(value: current, isSet: true);
  }

  static bool _hasConfiguredValue(ResolvedFieldValue resolved) => switch (resolved.value) {
    null => false,
    String value => value.trim().isNotEmpty,
    Map<Object?, Object?> value => value.isNotEmpty,
    Iterable<Object?> value => value.isNotEmpty,
    _ => resolved.isSet,
  };

  static bool _matchesFieldType(Object? value, ConfigFieldType type) => switch (type) {
    ConfigFieldType.string || ConfigFieldType.enum_ => value == null || value is String,
    ConfigFieldType.int_ => value == null || value is int,
    ConfigFieldType.double_ => value == null || value is num,
    ConfigFieldType.bool_ => value == null || value is bool,
    ConfigFieldType.stringList => value == null || value is List,
    ConfigFieldType.objectList => value == null || value is List,
    ConfigFieldType.objectMap => value == null || value is Map,
  };
}

class SettingsFieldView {
  new({
    required this.meta,
    required ResolvedFieldValue resolved,
    this.error,
    this.statusLabel,
    this.statusClass,
    String? placeholder,
  }) : kind = controlKindFor(meta),
       _resolved = resolved,
       _placeholder = placeholder;

  final FieldMeta meta;
  final SettingsControlKind kind;
  final String? error;
  final String? statusLabel;
  final String? statusClass;
  final ResolvedFieldValue _resolved;
  final String? _placeholder;
  bool get hasControl => kind != SettingsControlKind.fact && kind != SettingsControlKind.entries;
  bool get isEditable => hasControl && meta.mutability != ConfigMutability.readonly;
  String get stringValue => _stringValue(_resolved.value, meta.type);
  Map<String, Object?> toTemplateMap() {
    final badge = _tierBadge();
    return <String, Object?>{
      'path': meta.yamlPath,
      'controlId': controlIdFor(meta.yamlPath),
      'labelFor': hasControl ? controlIdFor(meta.yamlPath) : null,
      'label': labelFor(meta.yamlPath),
      'hint': meta.description,
      'badgeLabel': statusLabel ?? badge.label,
      'badgeClass': statusClass ?? badge.styleClass,
      'isText': kind == SettingsControlKind.text,
      'isNumber': kind == SettingsControlKind.number,
      'isTextarea': kind == SettingsControlKind.textarea,
      'isList': kind == SettingsControlKind.list,
      'isSelect': kind == SettingsControlKind.select,
      'isToggle': kind == SettingsControlKind.toggle,
      'isFact': kind == SettingsControlKind.fact,
      'isEntries': kind == SettingsControlKind.entries,
      'fieldClass': kind == SettingsControlKind.toggle ? 'form-field form-field--inline' : 'form-field',
      'inputClass': _inputClass(),
      'value': stringValue,
      'placeholder': _placeholder,
      'checked': _resolved.value == true ? true : null,
      'min': meta.min,
      'max': meta.max,
      'step': meta.type == ConfigFieldType.double_ ? 'any' : null,
      'options': _options(),
      'ariaInvalid': error == null ? null : 'true',
      'error': error ?? '',
      'factValue': _factValue(),
      'entryNote': _entryNote(),
      'entryFields': _entryFields(),
    };
  }

  ({String label, String styleClass}) _tierBadge() => switch (meta.mutability) {
    ConfigMutability.live => (label: 'live', styleClass: 'live-badge'),
    ConfigMutability.reloadable => (label: 'reload', styleClass: 'mode-badge'),
    ConfigMutability.restart => (label: 'restart', styleClass: 'mode-badge'),
    ConfigMutability.readonly => (label: 'read-only', styleClass: 'mode-badge'),
  };

  String _inputClass() {
    if (kind == SettingsControlKind.number) return 'form-input form-input--num t-body';
    final last = meta.yamlPath.split('.').last;
    if (last == 'host' || last == 'provider') return 'form-input form-input--short t-body';
    return 'form-input t-body';
  }

  List<Map<String, Object?>> _options() {
    if (kind != SettingsControlKind.select) return const [];
    final current = stringValue;
    final allowedValues = meta.allowedValues ?? const <String>[];
    final unset = !_resolved.isSet || _resolved.value == null;
    final unrecognized = !unset && current.isNotEmpty && !allowedValues.contains(current);
    return [
      if (meta.nullable || unset)
        {'value': '', 'label': meta.nullable ? 'Default' : 'Not set', 'selected': current.isEmpty ? true : null},
      if (unrecognized) {'value': current, 'label': '$current (not a recognized value)', 'selected': true},
      for (final allowed in allowedValues)
        {'value': allowed, 'label': allowed, 'selected': allowed == current ? true : null},
    ];
  }

  String _factValue() {
    if (kind != SettingsControlKind.fact) return '';
    if (settingsMaskedFields.contains(meta.yamlPath)) return _resolved.isSet ? 'Configured' : 'Not configured';
    if (!_resolved.isSet || _resolved.value == null) return 'Not set';
    return stringValue;
  }

  String _entryNote() {
    if (kind != SettingsControlKind.entries) return '';
    return switch (meta.entry) {
      OpaqueEntry(:final reason) => reason,
      ObjectEntry() => 'Each entry accepts the keys below. Edit this section in dartclaw.yaml.',
      ValueEntry() => 'Each entry is a single value. Edit this section in dartclaw.yaml.',
      null => 'Edit this section in dartclaw.yaml.',
    };
  }

  List<Map<String, Object?>> _entryFields() {
    return switch (meta.entry) {
      ObjectEntry(:final fields) => [
        for (final entry in fields.entries) {'name': entry.key, 'description': entry.value.description},
      ],
      ValueEntry(:final value) => [
        {'name': 'value', 'description': value.description},
      ],
      OpaqueEntry() || null => const [],
    };
  }
}

SettingsControlKind controlKindFor(FieldMeta meta) {
  if (settingsMaskedFields.contains(meta.yamlPath)) return SettingsControlKind.fact;
  if (meta.type == ConfigFieldType.objectList || meta.type == ConfigFieldType.objectMap) {
    return SettingsControlKind.entries;
  }
  if (meta.mutability == ConfigMutability.readonly) return SettingsControlKind.fact;
  return switch (meta.type) {
    ConfigFieldType.bool_ => SettingsControlKind.toggle,
    ConfigFieldType.enum_ => SettingsControlKind.select,
    ConfigFieldType.int_ || ConfigFieldType.double_ => SettingsControlKind.number,
    ConfigFieldType.stringList => SettingsControlKind.list,
    ConfigFieldType.string =>
      _longTextFields.contains(meta.yamlPath) ? SettingsControlKind.textarea : SettingsControlKind.text,
    ConfigFieldType.objectList || ConfigFieldType.objectMap => SettingsControlKind.entries,
  };
}

String controlIdFor(String yamlPath) => 'field-${yamlPath.replaceAll(RegExp('[._]'), '-')}';

String labelFor(String yamlPath) => humanizeSegment(yamlPath.split('.').last);

String? groupLabelFor(String yamlPath) {
  final segments = yamlPath.split('.');
  if (segments.length < 2) return null;
  return segments.sublist(0, segments.length - 1).map(humanizeSegment).join(' ');
}

const _acronyms = {
  'api': 'API',
  'cas': 'CAS',
  'db': 'DB',
  'dm': 'DM',
  'github': 'GitHub',
  'hsts': 'HSTS',
  'id': 'ID',
  'ids': 'IDs',
  'json': 'JSON',
  'kg': 'KG',
  'mb': 'MB',
  'mcp': 'MCP',
  'ms': 'ms',
  'qmd': 'QMD',
  'ttl': 'TTL',
  'url': 'URL',
  'yaml': 'YAML',
};

String humanizeSegment(String segment) {
  final spaced = segment.replaceAll('_', ' ').replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}');
  return spaced
      .split(' ')
      .where((word) => word.isNotEmpty)
      .map((word) => _acronyms[word.toLowerCase()] ?? '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

String _stringValue(Object? value, ConfigFieldType type) {
  if (value == null) return '';
  if (type == ConfigFieldType.stringList) {
    return value is List ? value.map((item) => '$item').join('\n') : '$value';
  }
  return '$value';
}
