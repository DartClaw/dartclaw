import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'config_meta.dart';
import 'config_validator.dart';

final _log = Logger('ConfigWriter');

class _WriteOp {
  final Future<void> Function() fn;
  final Completer<void> completer;
  new(this.fn) : completer = Completer<void>();
}

/// Non-destructive YAML config writer with backup and atomic writes.
///
/// Edits are surgical: comments, blank lines, key ordering, and unknown keys
/// outside the edited paths survive. A value written over an existing subtree
/// replaces it whole, comments inside it included. A symlinked [configPath] is
/// written through to its target; the link survives. Thread-safe via internal
/// write queue (serialized operations).
class ConfigWriter {
  /// configPath.
  final String configPath;
  final _queue = StreamController<_WriteOp>();
  late final StreamSubscription<void> _queueSub;

  /// ConfigWriter({required this.configPath}) {.
  new({required this.configPath}) {
    _queueSub = _queue.stream
        .asyncMap((op) async {
          try {
            await op.fn();
            op.completer.complete();
          } catch (e, st) {
            op.completer.completeError(e, st);
          }
        })
        .listen((_) {});
  }

  /// backupPath.
  String get backupPath => '$configPath.bak';

  /// Updates config fields and writes to disk.
  ///
  /// [updates] maps dot-separated YAML paths to new values.
  /// Example: `{'agent.model': 'sonnet', 'port': 3001}`
  ///
  /// A null value removes the key.
  /// Throws [FileSystemException] if the config file doesn't exist.
  /// Throws [StateError] if backup creation fails.
  Future<void> updateFields(Map<String, dynamic> updates) {
    if (updates.isEmpty) return Future.value();

    final memoryUpdates = {
      for (final entry in updates.entries)
        if (entry.key == 'memory.max_bytes' || entry.key == 'memory.pruning.archive_after_days') entry.key: entry.value,
    };
    final errors = const ConfigValidator().validate(memoryUpdates);
    if (errors.isNotEmpty) {
      throw ArgumentError(errors.map((error) => error.message).join('; '));
    }

    final op = _WriteOp(() => _doUpdate(updates));
    _queue.add(op);
    return op.completer.future;
  }

  Future<void> _doUpdate(Map<String, dynamic> updates) async {
    final file = File(configPath);

    // Read current content (fresh read — no cache)
    final content = await file.readAsString();

    final editor = YamlEditor(content);
    for (final entry in updates.entries) {
      final value = entry.value;
      applyEdit(editor, entry.key.split('.'), value == null ? null : _persistable(entry.key, value as Object));
    }

    // Backup: copy current file to .bak — abort on failure
    try {
      await file.copy(backupPath);
    } catch (e) {
      throw StateError('Backup failed, aborting config write: $e');
    }

    // Atomic write: temp file + rename onto the resolved target. Renaming onto
    // a symlinked configPath would replace the link with a regular file and
    // detach the instance from the file the operator versions.
    final targetPath = await file.resolveSymbolicLinks();
    final tempFile = File('$targetPath.tmp');
    await tempFile.writeAsString(editor.toString());
    await tempFile.rename(targetPath);
  }

  /// Narrows a whole-number `double` to `int` for a field declared
  /// [ConfigFieldType.int_].
  ///
  /// The validator accepts `3000.0` for an integer field because JSON decoders
  /// emit doubles for whole numbers, but the loader's integer readers accept
  /// only `int` and `String` — persisting the double verbatim would write YAML
  /// that reloads to the field's default, or, for the two `memory` keys whose
  /// reader throws, refuses to load at all.
  Object _persistable(String yamlPath, Object value) {
    if (value is! double || !value.isFinite || value != value.toInt().toDouble()) return value;
    if (ConfigMeta.fields[yamlPath]?.type != ConfigFieldType.int_) return value;
    return value.toInt();
  }

  /// Applies one edit to [editor]: a null [value] removes [path] (an absent
  /// path is a no-op), any other value is written there, creating missing
  /// intermediate maps first.
  ///
  /// Collections in [value] – including `YamlMap`/`YamlList` nodes read back
  /// from a document – are handed to the editor as plain Dart maps and lists.
  /// A `YamlNode` re-emits in its source style, so a flow collection read from
  /// the file would land at column 0 and the edit would assert.
  static void applyEdit(YamlEditor editor, List<String> path, Object? value) {
    if (value == null) {
      try {
        editor.remove(path);
      } on ArgumentError {
        // Already absent.
      }
      return;
    }
    final plain = _deepConvert(value) as Object;
    try {
      editor.update(path, plain);
    } on ArgumentError {
      // Path traversal failed: seed an empty root document, then create each
      // missing intermediate map.
      if (editor.parseAt([]).value == null) {
        editor.update([], {});
      }
      for (var i = 0; i < path.length - 1; i++) {
        final subPath = path.sublist(0, i + 1);
        try {
          editor.parseAt(subPath);
        } on ArgumentError {
          editor.update(subPath, {});
        }
      }
      editor.update(path, plain);
    }
  }

  /// Returns the last backup timestamp, or null if no backup exists.
  DateTime? get lastBackupTime {
    final backup = File(backupPath);
    if (!backup.existsSync()) return null;
    return backup.lastModifiedSync();
  }

  /// Reads the whole YAML config document as plain Dart maps and lists.
  ///
  /// Reads fresh from disk on each call. An absent or unparseable file answers
  /// an empty map: a caller resolving one key cannot tell that apart from an
  /// absent key anyway, and this is a read-only view — nothing is written back
  /// through it.
  Map<String, dynamic> readDocument() {
    final file = File(configPath);
    if (!file.existsSync()) return const {};
    try {
      final decoded = _deepConvert(loadYaml(file.readAsStringSync()));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (e) {
      _log.warning('Failed to read config document: $e');
      return const {};
    }
  }

  /// Reads the current scheduling jobs from the YAML config file.
  ///
  /// Reads fresh from disk on each call — not from a cached startup snapshot.
  /// Returns an empty list if `scheduling.jobs` is absent or unreadable.
  Future<List<Map<String, dynamic>>> readSchedulingJobs() async {
    final file = File(configPath);
    if (!file.existsSync()) return [];
    try {
      final content = await file.readAsString();
      final editor = YamlEditor(content);
      final value = editor.parseAt(['scheduling', 'jobs']).value;
      if (value is! List) return [];
      return value.map((item) {
        if (item is Map) {
          return {for (final e in item.entries) e.key.toString(): e.value};
        }
        return <String, dynamic>{};
      }).toList();
    } on ArgumentError {
      return []; // 'scheduling.jobs' path doesn't exist in YAML
    } catch (e) {
      _log.warning('Failed to read scheduling jobs: $e');
      return [];
    }
  }

  /// Reads a channel allowlist from the YAML config file.
  ///
  /// Reads from `channels.<channelType>.<fieldName>` (e.g. `channels.whatsapp.dm_allowlist`).
  /// Returns an empty list if the path is absent or unreadable.
  Future<List<String>> readChannelAllowlist(String channelType, String fieldName) async {
    final file = File(configPath);
    if (!file.existsSync()) return [];
    try {
      final content = await file.readAsString();
      final editor = YamlEditor(content);
      final value = editor.parseAt(['channels', channelType, fieldName]).value;
      if (value is! List) return [];
      return value.whereType<String>().toList();
    } on ArgumentError {
      return [];
    } catch (e) {
      _log.warning('Failed to read channel allowlist: $e');
      return [];
    }
  }

  /// Recursively converts YAML map/list values to standard Dart types.
  static dynamic _deepConvert(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{for (final e in value.entries) e.key.toString(): _deepConvert(e.value)};
    }
    if (value is List) {
      return value.map(_deepConvert).toList();
    }
    return value;
  }

  /// Writes a channel allowlist to the YAML config file.
  ///
  /// Writes to `channels.<channelType>.<fieldName>` using the write queue.
  Future<void> writeChannelAllowlist(String channelType, String fieldName, List<String> entries) {
    return updateFields({'channels.$channelType.$fieldName': entries});
  }

  /// Disposes the write queue. Call on shutdown.
  Future<void> dispose() async {
    await _queue.close();
    await _queueSub.cancel();
  }
}
