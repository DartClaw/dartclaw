part of 'dartclaw_config.dart';

/// What one sweep of a loaded YAML document found.
///
/// [unaccepted] is in document order so an operator fixes the file top-down;
/// [legacy] names the tolerated rows the document actually matched, so the
/// caller can announce the rows that own their own wording.
typedef ConfigPathSweep = ({List<String> unaccepted, List<ToleratedLegacyKey> legacy});

/// Walks [yaml] once and reports the paths nothing describes.
///
/// Rejection breadth is exactly the registry's declared breadth, less the
/// tolerated-legacy set. A path is accepted when [fields] registers it, when it
/// leads to a registered path, when a [tolerated] row names it, or when its
/// first segment belongs to a registered extension parser.
///
/// Three things are leaves rather than sections to walk: a list value, a
/// section under a registered extension key, and the value of a field that
/// declares a [ConfigEntryShape]. The last is why a `providers.<id>` or
/// `agent.agents.<name>` block is accepted whole — a shape states what an entry
/// *may* contain, for a consumer that renders or validates it, while the owning
/// parser decides what an entry may *not*, and several of those parsers keep an
/// open per-entry map on purpose.
///
/// Registration alone is not a leaf: where the registry declares fields *below*
/// a registered path the walk keeps going, so registering a container does not
/// retire the sweep over its described children. Under an entry-shaped
/// container the two compose — a child the registry describes is walked, and
/// any other child is one of the container's operator-named entries and is
/// accepted whole.
///
/// Decides membership only — never severity. The caller chooses what a
/// non-empty [ConfigPathSweep.unaccepted] costs.
ConfigPathSweep _sweepConfigPaths(
  Map<Object?, Object?> yaml, {
  required Set<String> extensionKeys,
  required Map<String, FieldMeta> fields,
  required Map<String, ToleratedLegacyKey> tolerated,
}) {
  final walk = _ConfigPathWalk(extensionKeys: extensionKeys, fields: fields, tolerated: tolerated);
  walk.section(yaml, '');
  return (unaccepted: walk.unaccepted, legacy: walk.legacy);
}

class _ConfigPathWalk {
  final Set<String> extensionKeys;
  final Map<String, FieldMeta> fields;
  final Map<String, ToleratedLegacyKey> tolerated;

  /// Every proper prefix of a described path — the sections the walk may
  /// descend into because something below them is described.
  final Set<String> descendable;

  final List<String> unaccepted = [];
  final List<ToleratedLegacyKey> legacy = [];

  new({required this.extensionKeys, required this.fields, required this.tolerated})
    : descendable = _properPrefixes([...fields.keys, ...tolerated.keys]);

  /// [underEntryShape] marks [map] as the value of a field declaring a
  /// [ConfigEntryShape], so a key the registry does not describe is one of its
  /// entries rather than a typo.
  void section(Map<Object?, Object?> map, String parent, {bool underEntryShape = false}) {
    for (final entry in map.entries) {
      final key = entry.key.toString();
      final path = parent.isEmpty ? key : '$parent.$key';

      if (parent.isEmpty && extensionKeys.contains(key)) continue;

      final field = fields[path];
      if (field != null) {
        if (descendable.contains(path)) _descend(entry.value, path, underEntryShape: field.entry != null);
        continue;
      }

      final row = tolerated[path];
      if (row != null) {
        legacy.add(row);
        if (row.match == LegacyKeyMatch.exact) _descend(entry.value, path);
        continue;
      }

      if (descendable.contains(path)) {
        _descend(entry.value, path);
        continue;
      }

      if (underEntryShape) continue;

      unaccepted.add(path);
    }
  }

  void _descend(Object? value, String path, {bool underEntryShape = false}) {
    if (value case final Map<Object?, Object?> map) section(map, path, underEntryShape: underEntryShape);
  }
}

Set<String> _properPrefixes(Iterable<String> paths) {
  final prefixes = <String>{};
  for (final path in paths) {
    final segments = path.split('.');
    for (var length = 1; length < segments.length; length++) {
      prefixes.add(segments.take(length).join('.'));
    }
  }
  return prefixes;
}

/// The startup refusal for a document carrying paths nothing describes.
///
/// Names every offending path in one failure so an operator fixes the file in
/// one pass, and points at the one sanctioned way to keep a section DartClaw
/// does not own.
FormatException _unknownConfigFields(List<String> paths) {
  return FormatException(
    'Unrecognized configuration — refusing to start with defaults:\n'
    '${paths.map((path) => '  ${unknownConfigFieldMessage(path)}').join('\n')}\n'
    'Delete or correct these keys, or register a custom top-level section with '
    'DartclawConfig.registerExtensionParser before loading.',
  );
}
