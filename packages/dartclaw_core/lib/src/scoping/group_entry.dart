/// A structured allowlist row – a DM peer or a group – carrying an optional
/// display name, project binding, model override, effort override and the
/// logical agent the conversation is bound to.
///
/// Plain-string allowlist entries are represented as `GroupEntry(id: id)` with
/// all optional fields null — functionally equivalent to the previous
/// `List<String>` representation.
class GroupEntry {
  /// The channel-specific identifier: a DM peer id, or a group id (WhatsApp
  /// JID, Signal group ID, Google Chat space name).
  final String id;

  /// Optional human-readable display name shown in the session sidebar.
  final String? name;

  /// Optional project ID for task creation routing.
  final String? project;

  /// Optional model override for turns from this row.
  final String? model;

  /// Optional effort override for turns from this row.
  final String? effort;

  /// Optional `agent.agents.<name>` this row's conversation runs as; null
  /// means the primary agent.
  final String? agent;

  const new({required this.id, this.name, this.project, this.model, this.effort, this.agent});

  /// Parses a mixed YAML list of strings and maps into a [GroupEntry] list.
  ///
  /// [field] is the config path being parsed (e.g. `whatsapp.dm_allowlist`)
  /// and prefixes every warning.
  ///
  /// - Plain `String` items become `GroupEntry(id: item)`.
  /// - `Map` items with an `id` key become fully structured entries.
  /// - `Map` items without `id`, non-string/non-map items, and maps with an
  ///   empty `id` are skipped with a warning via [onWarning].
  /// - Duplicate IDs: last entry wins (with warning).
  /// - Whitespace-only [name] is treated as null.
  /// - Unknown keys in a map entry are ignored with a warning.
  static List<GroupEntry> parseList(List<dynamic>? raw, {required String field, void Function(String)? onWarning}) {
    if (raw == null || raw.isEmpty) return const [];

    final seen = <String, GroupEntry>{};
    const knownKeys = {'id', 'name', 'project', 'model', 'effort', 'agent'};

    for (final item in raw) {
      if (item is String) {
        seen[item] = GroupEntry(id: item);
      } else if (item is Map) {
        final idRaw = item['id'];
        if (idRaw is! String || idRaw.trim().isEmpty) {
          onWarning?.call('$field: map missing or invalid "id" field — skipping');
          continue;
        }
        final id = idRaw;

        for (final key in item.keys) {
          if (!knownKeys.contains(key.toString())) {
            onWarning?.call('$field: unknown key "$key" in entry for id "$id" — ignoring');
          }
        }

        final nameRaw = item['name'];
        final name = nameRaw is String && nameRaw.trim().isNotEmpty ? nameRaw.trim() : null;
        final project = item['project'] is String ? item['project'] as String : null;
        final model = item['model'] is String ? item['model'] as String : null;
        final effort = item['effort'] is String ? item['effort'] as String : null;
        final Object? agentRaw = item['agent'];
        final String? agent;
        if (!item.containsKey('agent')) {
          agent = null;
        } else if (agentRaw is String && agentRaw.trim().isNotEmpty) {
          agent = agentRaw;
        } else {
          throw FormatException(
            'channels.$field: row "$id" has an invalid agent; expected a non-blank string, got $agentRaw.',
          );
        }

        if (seen.containsKey(id)) {
          onWarning?.call('$field: duplicate id "$id" — last entry wins');
        }
        seen[id] = GroupEntry(id: id, name: name, project: project, model: model, effort: effort, agent: agent);
      } else {
        onWarning?.call('$field: invalid item type "${item.runtimeType}" — skipping: $item');
      }
    }

    return seen.values.toList();
  }

  /// Returns the ids from [entries] as a plain string list – the shape every
  /// access check consumes.
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
          effort == other.effort &&
          agent == other.agent;

  @override
  int get hashCode => Object.hash(id, name, project, model, effort, agent);

  @override
  String toString() =>
      'GroupEntry(id: $id, name: $name, project: $project, model: $model, effort: $effort, agent: $agent)';
}
