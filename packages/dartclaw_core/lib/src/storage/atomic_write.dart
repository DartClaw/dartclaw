import 'dart:convert';
import 'dart:io';

/// Writes [contents] to [target] atomically: writes to a temp file first,
/// then renames to the final path. Prevents partial reads on crash.
Future<void> atomicWriteJson(File target, Object json) async {
  final tempFile = File('${target.path}.tmp');
  await tempFile.writeAsString(jsonEncode(json));
  await tempFile.rename(target.path);
}
