import 'dart:convert';

part 'config_meta/json_schema.dart';
part 'config_meta/server_fields.dart';
part 'config_meta/agent_fields.dart';
part 'config_meta/channel_fields.dart';
part 'config_meta/governance_fields.dart';

/// Mutability classification for config fields.
enum ConfigMutability {
  /// Takes effect immediately via Tier 1 service APIs.
  live,

  /// Written to YAML, applied immediately via ConfigNotifier.reload().
  reloadable,

  /// Written to YAML, applied on next startup.
  restart,

  /// Visible but not editable via API.
  readonly,
}

/// Type of a config field.
enum ConfigFieldType {
  /// Integer scalar.
  int_,

  /// Fractional scalar — a value whose parse site accepts a non-integral
  /// number, so declaring it [int_] would refuse a value the loader honours.
  double_,

  /// String scalar.
  string,

  /// Boolean scalar.
  bool_,

  /// Enumerated string scalar.
  enum_,

  /// List of strings.
  stringList,

  /// List of object maps.
  objectList,

  /// Object map keyed by name.
  objectMap,
}

/// Shape of a *single* entry inside a [ConfigFieldType.objectList] or
/// [ConfigFieldType.objectMap] field.
///
/// Sealed so a consumer that renders or validates an entry can switch
/// exhaustively instead of matching on the owning field's path.
sealed class ConfigEntryShape {
  /// Creates a [ConfigEntryShape] value.
  const new();
}

/// One entry is a map of named fields, keyed by their dotted path relative to
/// the entry root.
final class ObjectEntry extends ConfigEntryShape {
  /// Entry fields keyed by their path relative to the entry root.
  final Map<String, EntryFieldMeta> fields;

  /// Creates an [ObjectEntry] value.
  const new({required this.fields});
}

/// One entry is a single value rather than a map — e.g. `alerts.routes`, whose
/// entries are string lists keyed by alert type.
final class ValueEntry extends ConfigEntryShape {
  /// Shape of the entry's value.
  final EntryFieldMeta value;

  /// Creates a [ValueEntry] value.
  const new({required this.value});
}

/// One entry has no shape DartClaw can declare, because the keys inside it are
/// defined by the operator or by a component outside this registry.
///
/// [reason] states why, so a consumer renders the gap rather than guessing.
final class OpaqueEntry extends ConfigEntryShape {
  /// Why the entry's shape is not declared here.
  final String reason;

  /// Creates an [OpaqueEntry] value.
  const new({required this.reason}) : assert(reason != '', 'An opaque entry must state its reason');
}

/// Metadata describing one field *inside* an entry shape.
///
/// Carries no `mutability` and no `jsonKey`: an entry is replaced through its
/// container, so the container's reload tier and JSON key govern.
class EntryFieldMeta {
  /// Value type accepted for this field inside one entry.
  final ConfigFieldType type;

  /// A second scalar type the parser also accepts for this field, or null when
  /// it accepts [type] alone.
  final ConfigFieldType? alsoAccepts;

  /// Human-readable description of what the field controls. Never blank.
  final String description;

  /// Whether `null` is a valid value.
  final bool nullable;

  /// For [ConfigFieldType.int_] / [ConfigFieldType.double_]: minimum allowed
  /// value (inclusive).
  final int? min;

  /// For [ConfigFieldType.int_] / [ConfigFieldType.double_]: maximum allowed
  /// value (inclusive).
  final int? max;

  /// For [ConfigFieldType.enum_]: allowed string values.
  final List<String>? allowedValues;

  /// For object-typed fields: the shape of one nested entry.
  final ConfigEntryShape? entry;

  /// Creates an [EntryFieldMeta] value.
  const new({
    required this.type,
    required this.description,
    this.alsoAccepts,
    this.nullable = false,
    this.min,
    this.max,
    this.allowedValues,
    this.entry,
  }) : assert(description != '', 'Every entry field must carry a description'),
       assert(alsoAccepts != type, 'An alternative type must differ from the declared one'),
       assert(
         entry == null || (min == null && max == null && allowedValues == null),
         'An entry shape and scalar constraints are mutually exclusive',
       ),
       assert(
         entry == null || type == ConfigFieldType.objectList || type == ConfigFieldType.objectMap,
         'Only objectList and objectMap fields carry an entry shape',
       );
}

/// How far a [ToleratedLegacyKey] row reaches.
enum LegacyKeyMatch {
  /// The row tolerates its own path only. Anything nested under it is resolved
  /// normally, so a typo inside a deprecated block is still reported.
  exact,

  /// The row tolerates its path and everything under it, unexamined — for a
  /// block whose inner shape DartClaw stopped describing when it retired the
  /// block.
  subtree,
}

/// One YAML path the loader still accepts but never exposes as a field.
///
/// A path is here because DartClaw itself made it real — its own parser still
/// names it, or a shipped example or testing profile has carried it — so an
/// upgrading install keeps booting. It is *not* a second schema: a row carries
/// no type, bound or mutability, only the reach of the tolerance and what to
/// tell the operator.
class ToleratedLegacyKey {
  /// Dot-separated YAML path this row tolerates.
  final String path;

  /// How far the tolerance reaches.
  final LegacyKeyMatch match;

  /// Operator-facing text stating what replaces [path], or why it is ignored.
  ///
  /// Emitted verbatim at load when [announcedBySweep].
  final String replacement;

  /// Whether the load sweep announces this row itself.
  ///
  /// `false` where a parser site already emits its own advisory for [path], so
  /// an operator sees one message rather than two. A story that deletes such a
  /// site flips this to `true` in the same change, or the path goes silent.
  final bool announcedBySweep;

  /// Creates a [ToleratedLegacyKey] row.
  const new({required this.path, required this.match, required this.replacement, this.announcedBySweep = true})
    : assert(replacement != '', 'Every tolerated legacy key must state its replacement or reason');
}

/// Metadata describing a single config field.
class FieldMeta {
  /// Dot-separated YAML path (e.g., `'scheduling.heartbeat.interval_minutes'`).
  final String yamlPath;

  /// CamelCase JSON key for API responses (e.g., `'scheduling.heartbeat.intervalMinutes'`).
  final String jsonKey;

  /// type.
  final ConfigFieldType type;

  /// A second scalar type the parser also accepts for this field, or null when
  /// it accepts [type] alone.
  ///
  /// Declared rather than inferred so every consumer — write path, form,
  /// published schema — reads the same union instead of hard-coding
  /// [yamlPath]. [type] stays the canonical one: it is what the write path
  /// enforces and what a form control is built from.
  final ConfigFieldType? alsoAccepts;

  /// mutability.
  final ConfigMutability mutability;

  /// Human-readable description of what the field controls. Never blank.
  ///
  /// States unit, default and consequence rather than restating [yamlPath] —
  /// a description that only paraphrases the key gives an editor hover nothing.
  final String description;

  /// Whether `null` is a valid value (field removal).
  final bool nullable;

  /// For [ConfigFieldType.int_] / [ConfigFieldType.double_]: minimum allowed
  /// value (inclusive).
  final int? min;

  /// For [ConfigFieldType.int_] / [ConfigFieldType.double_]: maximum allowed
  /// value (inclusive).
  final int? max;

  /// For [ConfigFieldType.enum_]: allowed string values.
  final List<String>? allowedValues;

  /// For [ConfigFieldType.objectList] / [ConfigFieldType.objectMap]: the shape
  /// of one entry, so a consumer can validate or render it without hard-coding
  /// [yamlPath].
  final ConfigEntryShape? entry;

  /// Creates a [FieldMeta] value.
  const new({
    required this.yamlPath,
    required this.jsonKey,
    required this.type,
    required this.mutability,
    required this.description,
    this.alsoAccepts,
    this.nullable = false,
    this.min,
    this.max,
    this.allowedValues,
    this.entry,
  }) : assert(description != '', 'Every field must carry a description'),
       assert(alsoAccepts != type, 'An alternative type must differ from the declared one'),
       assert(
         entry == null || (min == null && max == null && allowedValues == null),
         'An entry shape and scalar constraints are mutually exclusive',
       ),
       assert(
         entry == null || type == ConfigFieldType.objectList || type == ConfigFieldType.objectMap,
         'Only objectList and objectMap fields carry an entry shape',
       );
}

/// Static registry of all config field metadata.
///
/// Centralizes field definitions, mutability classification, type constraints,
/// and the canonical YAML-path-to-JSON-key mapping. Used by [ConfigValidator]
/// for validation and by the config API for `_meta.fields` responses.
abstract final class ConfigMeta {
  /// All registered fields keyed by YAML path.
  ///
  /// Assembled by const-spread from the per-section `part` files, so a
  /// duplicate `yamlPath` is a compile error rather than a test failure.
  static const Map<String, FieldMeta> fields = {
    ..._serverFields,
    ..._agentFields,
    ..._channelFields,
    ..._governanceFields,
  };

  /// YAML paths the loader still accepts for a migration advisory but never
  /// exposes as fields, keyed by path.
  ///
  /// These are deliberately *not* [fields] entries: they are unsettable and
  /// must not be schema-emitted. The load sweep that rejects an undescribed key
  /// consults this set too, so a config DartClaw once shipped keeps booting.
  ///
  /// This is the receiving artifact for every path a story deregisters from
  /// [fields]: deregistering without adding a row here turns an un-migrated
  /// config into a boot failure. `config_meta_test.dart` pins the membership,
  /// and a companion gate pins every row to a CHANGELOG deprecation entry, so
  /// a deferred break stays announced rather than becoming permanent silence.
  static const Map<String, ToleratedLegacyKey> toleratedLegacyKeys = {
    'channels.whatsapp.task_trigger': ToleratedLegacyKey(
      path: 'channels.whatsapp.task_trigger',
      match: LegacyKeyMatch.subtree,
      replacement: 'Removed channels.whatsapp.task_trigger block; create tasks with task_create.',
    ),
    'channels.signal.task_trigger': ToleratedLegacyKey(
      path: 'channels.signal.task_trigger',
      match: LegacyKeyMatch.subtree,
      replacement: 'Removed channels.signal.task_trigger block; create tasks with task_create.',
    ),
    'channels.google_chat.task_trigger': ToleratedLegacyKey(
      path: 'channels.google_chat.task_trigger',
      match: LegacyKeyMatch.subtree,
      replacement: 'Removed channels.google_chat.task_trigger block; create tasks with task_create.',
    ),
    'andthen': ToleratedLegacyKey(
      path: 'andthen',
      match: LegacyKeyMatch.subtree,
      replacement: 'Retired AndThen provisioning block; DartClaw no longer provisions AndThen skills.',
      announcedBySweep: false,
    ),
    'delegation': ToleratedLegacyKey(
      path: 'delegation',
      match: LegacyKeyMatch.subtree,
      replacement: 'Removed orchestration block; define logical agents under agent.agents and use sessions_spawn.',
      announcedBySweep: false,
    ),
    'tasks.max_concurrent': ToleratedLegacyKey(
      path: 'tasks.max_concurrent',
      match: LegacyKeyMatch.exact,
      replacement: 'Removed capacity knob; configure shared worker capacity with providers.<id>.pool_size.',
      announcedBySweep: false,
    ),
    'memory_max_bytes': ToleratedLegacyKey(
      path: 'memory_max_bytes',
      match: LegacyKeyMatch.exact,
      replacement: 'Deprecated top-level alias for memory.max_bytes; still applied at load with an advisory.',
      announcedBySweep: false,
    ),
    'guard_audit.max_entries': ToleratedLegacyKey(
      path: 'guard_audit.max_entries',
      match: LegacyKeyMatch.exact,
      replacement: 'Removed audit cap; guard_audit.max_retention_days governs audit retention instead.',
    ),
    'workflow.execution_mode': ToleratedLegacyKey(
      path: 'workflow.execution_mode',
      match: LegacyKeyMatch.exact,
      replacement: 'Removed in 0.16.4; workflow steps always use one-shot execution.',
      announcedBySweep: false,
    ),
    'container.mount_allowlist': ToleratedLegacyKey(
      path: 'container.mount_allowlist',
      match: LegacyKeyMatch.exact,
      replacement:
          'Removed host-mount list; its 0.24.2 rename target container.mounts is gone too, so there is no '
          'replacement — host paths are not mounted into agent containers from config.',
    ),
    'container.mounts': ToleratedLegacyKey(
      path: 'container.mounts',
      match: LegacyKeyMatch.exact,
      replacement:
          'Removed host-mount list; no replacement — host paths are not mounted into agent containers from config.',
    ),
    'container.extra_args': ToleratedLegacyKey(
      path: 'container.extra_args',
      match: LegacyKeyMatch.exact,
      replacement:
          'Removed Docker-argument list; no replacement — the argument vector comes from the security profile alone.',
    ),
    'automation.scheduled_tasks': ToleratedLegacyKey(
      path: 'automation.scheduled_tasks',
      match: LegacyKeyMatch.exact,
      replacement:
          'Removed scheduling alias; entries are rewritten at load into scheduling.jobs with type: task — move them '
          'there.',
      announcedBySweep: false,
    ),
    'channels.google_chat.space_events.auth_mode': ToleratedLegacyKey(
      path: 'channels.google_chat.space_events.auth_mode',
      match: LegacyKeyMatch.exact,
      replacement: 'Retired Space-events auth selector; the Pub/Sub subscription decides authentication.',
      announcedBySweep: false,
    ),
    'context.exploration_summary_threshold': ToleratedLegacyKey(
      path: 'context.exploration_summary_threshold',
      match: LegacyKeyMatch.exact,
      replacement:
          'Ignoring context.exploration_summary_threshold; it configured the deleted exploration summarizer and '
          'context.max_result_bytes is unaffected.',
    ),
    'advisor': ToleratedLegacyKey(
      path: 'advisor',
      match: LegacyKeyMatch.subtree,
      replacement: 'Ignoring removed advisor config; run supervision is the workflow orchestration agent.',
    ),
    'guards.input_sanitizer': ToleratedLegacyKey(
      path: 'guards.input_sanitizer',
      match: LegacyKeyMatch.subtree,
      replacement: 'Removed regex injection guard; the guards.content classifier is the only injection judge.',
      announcedBySweep: false,
    ),
    'canvas': ToleratedLegacyKey(
      path: 'canvas',
      match: LegacyKeyMatch.subtree,
      replacement: 'Ignoring canvas config; the section was removed in 0.18.0 and nothing reads it.',
    ),
    'crowd_coding': ToleratedLegacyKey(
      path: 'crowd_coding',
      match: LegacyKeyMatch.subtree,
      replacement:
          'Ignoring top-level crowd_coding config; enable features.thread_binding and set its policy under '
          'governance.crowd_coding.',
    ),
  };

  static Map<String, FieldMeta>? _byJsonKey;

  /// All registered fields keyed by JSON key.
  static Map<String, FieldMeta> get byJsonKey {
    return _byJsonKey ??= {for (final f in fields.values) f.jsonKey: f};
  }

  /// Returns fields matching the given [mutability].
  static Iterable<FieldMeta> forMutability(ConfigMutability mutability) {
    return fields.values.where((f) => f.mutability == mutability);
  }

  /// Whether [yamlPath] is a known config field.
  static bool isKnown(String yamlPath) => fields.containsKey(yamlPath);

  /// Projects the whole registry into a JSON Schema (draft 2020-12) over
  /// `dartclaw.yaml`, ready to be attached in a schema-aware editor.
  ///
  /// Describes every registered field regardless of [ConfigMutability]: the
  /// YAML file stays authoritative, so a read-only field is legal to write
  /// there and only the API refuses it. The tier is carried as description
  /// text, never as a validation keyword.
  ///
  /// [toleratedLegacyKeys] are not emitted, so a config still carrying one
  /// gets an editor warning the loader would not raise.
  static Map<String, Object?> toJsonSchema({required String version}) => _buildConfigJsonSchema(version);

  /// Published schema URL at the release tag for [version], without a `v` prefix.
  static String jsonSchemaUrl(String version) =>
      'https://raw.githubusercontent.com/DartClaw/dartclaw/v$version/schemas/dartclaw.schema.json';

  /// Schema for [version] as two-space-indented JSON with LF and one trailing newline.
  static String jsonSchemaSource({required String version}) =>
      '${const JsonEncoder.withIndent('  ').convert(toJsonSchema(version: version))}\n';

  /// Whether [yamlPath] exists and is not [ConfigMutability.readonly].
  static bool isWritable(String yamlPath) {
    final meta = fields[yamlPath];
    return meta != null && meta.mutability != ConfigMutability.readonly;
  }
}
