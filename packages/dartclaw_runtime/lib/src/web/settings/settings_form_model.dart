import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../../api/config_apply_service.dart';
import 'settings_field_view.dart';
import 'settings_sections.dart';

const settingsSectionFormField = '__section';

typedef SettingsFieldGroup = ({String label, List<SettingsFieldView> fields});

Map<String, Object?> buildSettingsPanelView({
  required SettingsPanel panel,
  required SettingsValueResolver resolver,
  List<FieldMeta>? fields,
  List<ValidationError> errors = const [],
  Set<String> applied = const {},
  Set<String> pendingRestart = const {},
  String? statusMessage,
}) {
  final errorByField = <String, String>{};
  for (final error in errors) {
    errorByField.putIfAbsent(error.field, () => error.message);
  }

  final groups = <SettingsFieldGroup>[];
  var currentLabel = panel.title;
  var currentFields = <SettingsFieldView>[];
  var started = false;

  void flush() {
    if (currentFields.isEmpty) return;
    groups.add((label: currentLabel, fields: currentFields));
    currentFields = <SettingsFieldView>[];
  }

  for (final meta in fields ?? settingsFieldsForPanel(panel)) {
    final label = groupLabelFor(meta.yamlPath) ?? panel.title;
    if (!started || label != currentLabel) {
      flush();
      currentLabel = label;
      started = true;
    }
    final resolved = resolver.resolve(meta);
    currentFields.add(
      SettingsFieldView(
        meta: meta,
        resolved: resolved,
        error: errorByField[meta.yamlPath],
        statusLabel: _statusLabel(meta.yamlPath, applied, pendingRestart),
        statusClass: _statusClass(meta.yamlPath, applied, pendingRestart),
        placeholder: _placeholderFor(meta, resolved, resolver),
      ),
    );
  }
  flush();

  final rendered = {
    for (final group in groups)
      for (final field in group.fields) field.meta.yamlPath,
  };

  final note = _mutabilityNote(groups);
  return {
    'sectionId': panel.id,
    'formId': 'settings-section-${panel.id}',
    'sectionField': settingsSectionFormField,
    'note': note,
    'hasNote': note.isNotEmpty,
    'statusMessage': statusMessage,
    'hasStatus': statusMessage != null,
    'statusClass': errors.isNotEmpty ? 'form-error t-caption' : 'form-hint t-caption',
    'unplacedErrors': [
      for (final error in errors)
        if (!rendered.contains(error.field)) error.message,
    ],
    'hasActions': groups.any((group) => group.fields.any((field) => field.isEditable)),
    'groups': [
      for (var index = 0; index < groups.length; index++)
        {
          'label': groups[index].label,
          'labelId': 'cluster-${panel.id}-$index',
          'fields': [for (final field in groups[index].fields) field.toTemplateMap()],
        },
    ],
  };
}

Map<String, dynamic> decodeSettingsSubmission({
  required SettingsPanel panel,
  required Map<String, String> form,
  required SettingsValueResolver resolver,
  List<FieldMeta>? fields,
}) {
  final editable = <String, FieldMeta>{
    for (final meta in fields ?? settingsFieldsForPanel(panel))
      if (controlKindFor(meta) != SettingsControlKind.fact && controlKindFor(meta) != SettingsControlKind.entries)
        meta.yamlPath: meta,
  };

  final changes = <String, dynamic>{};

  for (final meta in editable.values) {
    final present = form.containsKey(meta.yamlPath);
    // A form-encoded body omits an unchecked checkbox, so for a boolean absence
    // is `false` rather than "unchanged"; every other type is only judged when
    // its control was actually submitted.
    if (!present && meta.type != ConfigFieldType.bool_) continue;
    final value = meta.type == ConfigFieldType.bool_
        ? present && _isChecked(form[meta.yamlPath]!)
        : _coerce(meta, form[meta.yamlPath]!);
    if (_isUnchanged(meta, resolver.resolve(meta), value)) continue;
    changes[meta.yamlPath] = value;
  }

  for (final entry in form.entries) {
    if (entry.key == settingsSectionFormField || editable.containsKey(entry.key)) continue;
    // A key another panel owns is refused here rather than written invisibly:
    // the response re-renders only this section, so an accepted cross-panel
    // write would leave no trace on the page. Everything else — unknown,
    // read-only, owned by another surface — goes to the validator untouched, so
    // the refusal is the sentence `PATCH /api/config` returns.
    // A writable key another *surface* owns is refused first:
    // `settingsPanelForField` answers null for those prefixes, so the
    // cross-panel check below never sees them. Read-only and unknown keys still
    // fall through to the validator, keeping its sentences and PATCH parity.
    final ownedElsewhere = settingsFieldOwnerFor(entry.key);
    if (ownedElsewhere != null && ConfigMeta.isWritable(entry.key)) {
      throw SettingsSubmissionRefused("Field '${entry.key}' is not editable here – it belongs to $ownedElsewhere");
    }
    final owner = settingsPanelForField(entry.key);
    if (owner != null && owner.id != panel.id && ConfigMeta.isWritable(entry.key)) {
      throw SettingsSubmissionRefused("Field '${entry.key}' is not part of the ${panel.title} section");
    }
    changes[entry.key] = entry.value;
  }

  if (changes.containsKey('scheduling.jobs')) {
    // Mirrors the JSON tier's refusal so the two say the same thing.
    throw const SettingsSubmissionRefused('Use job CRUD endpoints for scheduling.jobs changes');
  }

  return normalizeConfigPatch(changes);
}

final class SettingsSubmissionRefused implements Exception {
  const new(this.message);
  final String message;

  @override
  String toString() => message;
}

bool _isUnchanged(FieldMeta meta, ResolvedFieldValue current, Object? submitted) {
  if (_sameValue(submitted, current.value)) return true;
  if (current.isSet && current.value != null) return false;
  return switch (meta.type) {
    ConfigFieldType.bool_ => submitted == false,
    ConfigFieldType.stringList => submitted is List && submitted.isEmpty,
    _ => submitted == null || (submitted is String && submitted.trim().isEmpty),
  };
}

String settingsSubmissionSummary(ConfigApplyResult result) {
  if (!result.isValid) return 'Nothing was saved — correct the fields below and try again.';
  if (result.applied.isEmpty && result.pendingRestart.isEmpty) return 'No changes to save.';
  if (result.pendingRestart.isEmpty) return 'Saved and applied.';
  if (result.applied.isEmpty) return 'Saved — a restart is needed before it takes effect.';
  return 'Saved — ${result.applied.length} applied, ${result.pendingRestart.length} waiting for a restart.';
}

String? _statusLabel(String path, Set<String> applied, Set<String> pendingRestart) {
  if (pendingRestart.contains(path)) return 'restart required';
  if (applied.contains(path)) return 'applied';
  return null;
}

String? _statusClass(String path, Set<String> applied, Set<String> pendingRestart) {
  if (pendingRestart.contains(path)) return 'restart-badge';
  if (applied.contains(path)) return 'live-badge';
  return null;
}

String? _placeholderFor(FieldMeta meta, ResolvedFieldValue resolved, SettingsValueResolver resolver) {
  if (resolved.isSet && resolved.value != null && '${resolved.value}'.isNotEmpty) return null;
  if (!SettingsValueResolver.inherits(meta.yamlPath)) return null;
  final inherited = resolver.inheritedValueFor(meta.yamlPath);
  return inherited == null ? 'Unset (inherits the agent default)' : 'Inherits $inherited';
}

String _mutabilityNote(List<SettingsFieldGroup> groups) {
  final present = <ConfigMutability>{
    for (final group in groups)
      for (final field in group.fields)
        if (field.isEditable) field.meta.mutability,
  };
  final tiers = [
    ConfigMutability.live,
    ConfigMutability.reloadable,
    ConfigMutability.restart,
  ].where(present.contains).toList();
  if (tiers.isEmpty) return '';
  if (tiers.length == 1) {
    return switch (tiers.single) {
      ConfigMutability.live => 'Changes apply live.',
      ConfigMutability.reloadable => 'Changes reload without a server restart.',
      _ => 'Changes apply after a server restart.',
    };
  }
  final phrases = tiers
      .map(
        (tier) => switch (tier) {
          ConfigMutability.live => 'live',
          ConfigMutability.reloadable => 'on reload',
          _ => 'after a server restart',
        },
      )
      .toList();
  final joined = phrases.length == 2
      ? phrases.join(' or ')
      : '${phrases.sublist(0, phrases.length - 1).join(', ')}, or ${phrases.last}';
  return 'Changes apply $joined, depending on the field.';
}

bool _isChecked(String value) => value.isNotEmpty && value != 'false';

Object? _coerce(FieldMeta meta, String rawValue) {
  // A browser submits a textarea with CRLF line endings whatever the stored
  // value uses, so an untouched multi-line field would otherwise read as an edit.
  final raw = rawValue.replaceAll('\r\n', '\n');
  final trimmed = raw.trim();
  switch (meta.type) {
    case ConfigFieldType.int_:
      if (trimmed.isEmpty) return null;
      // A non-numeric entry is handed on verbatim so the validator reports the
      // type mismatch rather than this decoder inventing a repair.
      return int.tryParse(trimmed) ?? raw;
    case ConfigFieldType.double_:
      if (trimmed.isEmpty) return null;
      return double.tryParse(trimmed) ?? raw;
    case ConfigFieldType.stringList:
      return [
        for (final line in raw.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];
    case ConfigFieldType.string:
    case ConfigFieldType.enum_:
      if (trimmed.isEmpty && meta.nullable) return null;
      return raw;
    case ConfigFieldType.bool_:
    case ConfigFieldType.objectList:
    case ConfigFieldType.objectMap:
      return raw;
  }
}

bool _sameValue(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameValue(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  if (a is String && b is String) return a == b;
  return a == b;
}
