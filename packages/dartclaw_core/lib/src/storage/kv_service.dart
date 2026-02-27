import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_write.dart';

class _WriteOp {
  final Future<void> Function() fn;
  final Completer<void> completer;
  _WriteOp(this.fn) : completer = Completer<void>();
}

class KvService {
  final String filePath;
  final _queue = StreamController<_WriteOp>();
  late final StreamSubscription<void> _queueSub;

  KvService({required this.filePath}) {
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

  Future<String?> get(String key) async {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final entry = map[key] as Map<String, dynamic>?;
    return entry?['value'] as String?;
  }

  Future<void> set(String key, String value) {
    final op = _WriteOp(() async {
      final file = File(filePath);
      Map<String, dynamic> map = {};
      if (file.existsSync()) {
        map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
      map[key] = {'value': value, 'updatedAt': DateTime.now().toIso8601String()};
      final dir = file.parent;
      if (!dir.existsSync()) await dir.create(recursive: true);
      await atomicWriteJson(file, map);
    });
    _queue.add(op);
    return op.completer.future;
  }

  Future<void> delete(String key) {
    final op = _WriteOp(() async {
      final file = File(filePath);
      if (!file.existsSync()) return;
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      map.remove(key);
      await atomicWriteJson(file, map);
    });
    _queue.add(op);
    return op.completer.future;
  }

  Future<void> dispose() async {
    await _queue.close();
    await _queueSub.cancel();
  }
}
