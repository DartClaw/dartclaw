import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'atomic_write.dart';

final _log = Logger('TurnStateStore');

/// Opens a turn-state store at [path].
TurnStateStore openTurnStateStore(String path) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  _sweepTempFiles(file);
  if (!file.existsSync()) {
    secureWriteFileSync(file, '{}', restrictPermissions: false);
  } else {
    try {
      _readStates(file);
    } on Object {
      final quarantine = File('$path.corrupt-${_utcFileTimestamp()}');
      file.renameSync(quarantine.path);
      _log.warning('Quarantined invalid turn state file at ${quarantine.path}');
      secureWriteFileSync(file, '{}', restrictPermissions: false);
    }
  }
  return TurnStateStore._(file);
}

/// File-backed storage for active turn state keyed by session ID.
class TurnStateStore {
  new _(this._file);

  final File _file;

  /// Stores or updates the active turn state for [sessionId].
  Future<void> set(String sessionId, String turnId, DateTime startedAt) async {
    final states = _readStates(_file);
    states[sessionId] = {'turnId': turnId, 'startedAt': startedAt.toIso8601String()};
    _writeStates(_file, states);
  }

  /// Deletes the active turn state for [sessionId] if it exists.
  Future<void> delete(String sessionId) async {
    final states = _readStates(_file);
    states.remove(sessionId);
    _writeStates(_file, states);
  }

  /// Returns all active turn states keyed by session ID in ascending key order.
  Future<Map<String, ({String turnId, DateTime startedAt})>> getAll() async {
    final encoded = _readStates(_file);
    final result = <String, ({String turnId, DateTime startedAt})>{};
    for (final sessionId in encoded.keys.toList()..sort()) {
      final state = encoded[sessionId]!;
      result[sessionId] = (turnId: state['turnId'] as String, startedAt: DateTime.parse(state['startedAt'] as String));
    }
    return result;
  }

  /// Releases this store. File-backed stores hold no open resources.
  Future<void> dispose() => Future.value();
}

Map<String, Map<String, Object?>> _readStates(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) throw const FormatException('Turn state must be a JSON object');
  final states = <String, Map<String, Object?>>{};
  for (final entry in decoded.entries) {
    final value = entry.value;
    if (value is! Map<String, dynamic> || value['turnId'] is! String || value['startedAt'] is! String) {
      throw const FormatException('Invalid turn state entry');
    }
    DateTime.parse(value['startedAt'] as String);
    states[entry.key] = {'turnId': value['turnId'], 'startedAt': value['startedAt']};
  }
  return states;
}

void _writeStates(File file, Map<String, Map<String, Object?>> states) {
  final ordered = <String, Map<String, Object?>>{};
  for (final key in states.keys.toList()..sort()) {
    ordered[key] = states[key]!;
  }
  secureWriteFileSync(file, jsonEncode(ordered), restrictPermissions: false);
}

void _sweepTempFiles(File target) {
  final prefix = '${target.path}.';
  for (final entity in target.parent.listSync()) {
    if (entity is File && entity.path.startsWith(prefix) && entity.path.endsWith('.tmp')) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // A concurrently held temp file is harmless and will be retried next open.
      }
    }
  }
}

String _utcFileTimestamp() => DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
