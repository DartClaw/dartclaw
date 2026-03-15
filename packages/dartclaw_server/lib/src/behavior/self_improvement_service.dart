import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class _WriteOp {
  final Future<void> Function() fn;
  final Completer<void> completer;

  _WriteOp(this.fn) : completer = Completer<void>();
}

/// Manages `errors.md` and `learnings.md` in the workspace.
///
/// `errors.md` is auto-populated on turn failures, guard blocks, and crashes.
/// `learnings.md` is written via `memory_save` with `category='learning'`.
/// Both are capped at [maxEntries] entries (oldest trimmed on write).
class SelfImprovementService {
  static final _log = Logger('SelfImprovementService');

  final String workspaceDir;
  final int maxEntries;

  final _queue = StreamController<_WriteOp>();
  late final StreamSubscription<void> _queueSub;

  SelfImprovementService({required this.workspaceDir, this.maxEntries = 50}) {
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

  String get _errorsPath => p.join(workspaceDir, 'errors.md');
  String get _learningsPath => p.join(workspaceDir, 'learnings.md');

  /// Appends an error entry to `errors.md`. Never throws — logs warnings on failure.
  Future<void> appendError({
    required String errorType,
    required String sessionId,
    required String context,
    String? resolution,
  }) {
    final op = _WriteOp(() async {
      try {
        final timestamp = DateTime.now().toUtc().toIso8601String();
        final buf = StringBuffer()
          ..writeln('## [$timestamp] $errorType')
          ..writeln('- Session: $sessionId')
          ..writeln('- Context: $context');
        if (resolution != null) {
          buf.writeln('- Resolution: $resolution');
        }
        buf.writeln();

        await _appendCapped(_errorsPath, buf.toString(), '## [');
      } catch (e) {
        _log.warning('Failed to write errors.md: $e');
      }
    });
    _queue.add(op);
    return op.completer.future;
  }

  /// Appends a learning entry to `learnings.md`. Never throws — logs warnings on failure.
  Future<void> appendLearning({required String text}) {
    final op = _WriteOp(() async {
      try {
        final timestamp = DateTime.now().toIso8601String().substring(0, 16).replaceFirst('T', ' ');
        final entry = '- [$timestamp] $text\n';

        await _appendCapped(_learningsPath, entry, '- [');
      } catch (e) {
        _log.warning('Failed to write learnings.md: $e');
      }
    });
    _queue.add(op);
    return op.completer.future;
  }

  /// Returns errors.md contents, or empty string if missing.
  Future<String> readErrors() async {
    try {
      final file = File(_errorsPath);
      if (file.existsSync()) return file.readAsStringSync();
    } catch (e) {
      _log.warning('Failed to read errors.md: $e');
    }
    return '';
  }

  /// Returns learnings.md contents, or empty string if missing.
  Future<String> readLearnings() async {
    try {
      final file = File(_learningsPath);
      if (file.existsSync()) return file.readAsStringSync();
    } catch (e) {
      _log.warning('Failed to read learnings.md: $e');
    }
    return '';
  }

  /// Appends [entry] to [filePath], capping at [maxEntries].
  /// [entryPrefix] is used to identify entry boundaries when parsing.
  Future<void> _appendCapped(String filePath, String entry, String entryPrefix) async {
    final file = File(filePath);
    final dir = file.parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);

    if (!file.existsSync()) {
      file.writeAsStringSync(entry);
      return;
    }

    final content = file.readAsStringSync();
    final entries = _parseEntries(content, entryPrefix);
    entries.add(entry);

    // Trim oldest entries if over cap
    while (entries.length > maxEntries) {
      entries.removeAt(0);
    }

    // Atomic write
    final tempFile = File('$filePath.tmp');
    tempFile.writeAsStringSync(entries.join());
    tempFile.renameSync(filePath);
  }

  /// Parses file content into individual entries based on [prefix].
  static List<String> _parseEntries(String content, String prefix) {
    if (content.trim().isEmpty) return [];

    final entries = <String>[];
    final lines = content.split('\n');
    final buf = StringBuffer();

    for (final line in lines) {
      if (line.startsWith(prefix) && buf.isNotEmpty) {
        entries.add(buf.toString());
        buf.clear();
      }
      buf.writeln(line);
    }
    if (buf.isNotEmpty) {
      entries.add(buf.toString());
    }

    return entries;
  }

  Future<void> dispose() async {
    await _queue.close();
    await _queueSub.cancel();
  }
}
