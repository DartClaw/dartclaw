/// A structured group allowlist entry carrying an optional display name, project
/// binding, model override, and effort override.
///
/// Plain-string allowlist entries are represented as `GroupEntry(id: id)` with
/// all optional fields null — functionally equivalent to the previous
/// `List<String>` representation.
class GroupEntry {
  /// The channel-specific group identifier (e.g. WhatsApp JID, Signal group ID,
  /// Google Chat space name).
  final String id;

  /// Optional human-readable display name shown in the session sidebar.
  final String? name;

  /// Optional project ID for task creation routing.
  final String? project;

  /// Optional model override for turns from this group.
  final String? model;

  /// Optional effort override for turns from this group.
  final String? effort;

  const GroupEntry({required this.id, this.name, this.project, this.model, this.effort});

  /// Parses a mixed YAML list of strings and maps into a [GroupEntry] list.
  ///
  /// - Plain `String` items become `GroupEntry(id: item)`.
  /// - `Map` items with an `id` key become fully structured entries.
  /// - `Map` items without `id`, non-string/non-map items, and maps with an
  ///   empty `id` are skipped with a warning via [onWarning].
  /// - Duplicate IDs: last entry wins (with warning).
  /// - Whitespace-only [name] is treated as null.
  /// - Unknown keys in a map entry are ignored with a warning.
  static List<GroupEntry> parseList(List<dynamic>? raw, {void Function(String)? onWarning}) {
    if (raw == null || raw.isEmpty) return const [];

    final seen = <String, GroupEntry>{};
    const knownKeys = {'id', 'name', 'project', 'model', 'effort'};

    for (final item in raw) {
      if (item is String) {
        seen[item] = GroupEntry(id: item);
      } else if (item is Map) {
        final idRaw = item['id'];
        if (idRaw is! String || idRaw.trim().isEmpty) {
          onWarning?.call('GroupEntry map missing or invalid "id" field — skipping');
          continue;
        }
        final id = idRaw;

        // Warn about unknown keys
        for (final key in item.keys) {
          if (!knownKeys.contains(key.toString())) {
            onWarning?.call('GroupEntry: unknown key "$key" in entry for id "$id" — ignoring');
          }
        }

        final nameRaw = item['name'];
        final name = nameRaw is String && nameRaw.trim().isNotEmpty ? nameRaw.trim() : null;
        final project = item['project'] is String ? item['project'] as String : null;
        final model = item['model'] is String ? item['model'] as String : null;
        final effort = item['effort'] is String ? item['effort'] as String : null;

        if (seen.containsKey(id)) {
          onWarning?.call('GroupEntry: duplicate id "$id" — last entry wins');
        }
        seen[id] = GroupEntry(id: id, name: name, project: project, model: model, effort: effort);
      } else {
        onWarning?.call('GroupEntry: invalid item type "${item.runtimeType}" — skipping: $item');
      }
    }

    return seen.values.toList();
  }

  /// Returns the group IDs from [entries] as a plain string list.
  ///
  /// Provides backward-compatible access equivalent to the previous
  /// `List<String> groupAllowlist` field.
  static List<String> groupIds(List<GroupEntry> entries) => entries.map((e) => e.id).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupEntry &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          project == other.project &&
          model == other.model &&
          effort == other.effort;

  @override
  int get hashCode => Object.hash(id, name, project, model, effort);

  @override
  String toString() => 'GroupEntry(id: $id, name: $name, project: $project, model: $model, effort: $effort)';
}
