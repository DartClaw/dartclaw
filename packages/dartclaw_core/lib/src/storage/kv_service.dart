import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_write.dart';
import 'write_op.dart';

/// Simple key-value store backed by a JSON file with atomic writes.
class KvService {
  final String filePath;
  Map<String, dynamic>? _cache;
  late final BoundedWriteQueue _queue;

  KvService({required this.filePath}) {
    _queue = BoundedWriteQueue();
  }

  Future<String?> get(String key) async {
    final map = await _ensureCache();
    final entry = map[key] as Map<String, dynamic>?;
    return entry?['value'] as String?;
  }

  Future<void> set(String key, String value) {
    final op = WriteOp(() async {
      final file = File(filePath);
      final nextMap = Map<String, dynamic>.from(await _ensureCache());
      nextMap[key] = {'value': value, 'updatedAt': DateTime.now().toIso8601String()};
      final dir = file.parent;
      if (!dir.existsSync()) await dir.create(recursive: true);
      try {
        await atomicWriteJson(file, nextMap);
        _cache = nextMap;
      } catch (_) {
        _cache = null;
        rethrow;
      }
    });
    _queue.add(op);
    return op.completer.future;
  }

  /// Returns all entries whose key starts with [prefix].
  Future<Map<String, String>> getByPrefix(String prefix) async {
    final map = await _ensureCache();
    final result = <String, String>{};
    for (final entry in map.entries) {
      if (entry.key.startsWith(prefix)) {
        final value = (entry.value as Map<String, dynamic>)['value'] as String?;
        if (value != null) result[entry.key] = value;
      }
    }
    return result;
  }

  Future<void> delete(String key) {
    final op = WriteOp(() async {
      final file = File(filePath);
      if (!file.existsSync() && (_cache == null || _cache!.isEmpty)) return;

      final nextMap = Map<String, dynamic>.from(await _ensureCache());
      nextMap.remove(key);

      final dir = file.parent;
      if (!dir.existsSync()) await dir.create(recursive: true);
      try {
        await atomicWriteJson(file, nextMap);
        _cache = nextMap;
      } catch (_) {
        _cache = null;
        rethrow;
      }
    });
    _queue.add(op);
    return op.completer.future;
  }

  Future<void> dispose() async {
    await _queue.close();
  }

  Future<Map<String, dynamic>> _ensureCache() async {
    final cache = _cache;
    if (cache != null) return cache;

    final file = File(filePath);
    if (!file.existsSync()) {
      final empty = <String, dynamic>{};
      _cache = empty;
      return empty;
    }

    final loaded = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    _cache = loaded;
    return loaded;
  }
}
