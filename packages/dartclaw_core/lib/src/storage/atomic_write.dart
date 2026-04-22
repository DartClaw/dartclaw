import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _tempSuffixRand = Random();

/// Writes [contents] to [target] atomically: writes to a temp file first,
/// then renames to the final path. Prevents partial reads on crash and —
/// because the temp name carries a per-call random suffix — tolerates
/// concurrent writers racing on the same [target] without OS-level
/// "file not found" errors during rename.
///
/// Note: concurrency safety is limited to avoiding crashes during the
/// write/rename dance. The final contents of [target] are last-writer-wins;
/// callers that need read-modify-write semantics under contention should
/// serialise their own access above this utility.
Future<void> atomicWriteJson(File target, Object json) async {
  final suffix = '${DateTime.now().microsecondsSinceEpoch}-${_tempSuffixRand.nextInt(0x7fffffff).toRadixString(16)}';
  final tempFile = File('${target.path}.$suffix.tmp');
  try {
    await tempFile.writeAsString(jsonEncode(json));
    await tempFile.rename(target.path);
  } catch (_) {
    // Best-effort cleanup if rename failed partway; rethrow original error.
    if (tempFile.existsSync()) {
      try {
        await tempFile.delete();
      } catch (_) {
        // Swallow cleanup errors — original failure already in flight.
      }
    }
    rethrow;
  }
}
