import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _tempSuffixRand = Random();

/// Atomically writes [json] to [target] via random temp file + rename.
/// Last writer wins; callers needing read-modify-write safety must lock above.
Future<void> atomicWriteJson(File target, Object json) async {
  final suffix = '${DateTime.now().microsecondsSinceEpoch}-${_tempSuffixRand.nextInt(0x7fffffff).toRadixString(16)}';
  final tempFile = File('${target.path}.$suffix.tmp');
  try {
    await tempFile.writeAsString(jsonEncode(json));
    await tempFile.rename(target.path);
  } catch (_) {
    if (tempFile.existsSync()) {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
    rethrow;
  }
}

String _tempSuffix() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_tempSuffixRand.nextInt(0x7fffffff).toRadixString(16)}';

/// Atomically writes [contents], optionally chmoding the temp file before write.
Future<void> secureWriteFile(File target, String contents, {bool restrictPermissions = true}) =>
    _secureWriteFile(target, contents, restrictPermissions: restrictPermissions, chmod: chmodOwnerOnly);

Future<void> _secureWriteFile(
  File target,
  String contents, {
  required bool restrictPermissions,
  required Future<void> Function(String path) chmod,
}) async {
  final tempFile = File('${target.path}.${_tempSuffix()}.tmp');
  try {
    if (restrictPermissions) {
      await tempFile.create(exclusive: true);
      await chmod(tempFile.path);
    }
    await tempFile.writeAsString(contents, flush: true);
    await tempFile.rename(target.path);
  } catch (_) {
    if (tempFile.existsSync()) {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
    rethrow;
  }
}

/// Synchronous counterpart to [secureWriteFile].
void secureWriteFileSync(File target, String contents, {bool restrictPermissions = true}) =>
    _secureWriteFileSync(target, contents, restrictPermissions: restrictPermissions, chmod: chmodOwnerOnlySync);

void _secureWriteFileSync(
  File target,
  String contents, {
  required bool restrictPermissions,
  required void Function(String path) chmod,
}) {
  final tempFile = File('${target.path}.${_tempSuffix()}.tmp');
  try {
    if (restrictPermissions) {
      tempFile.createSync(exclusive: true);
      chmod(tempFile.path);
    }
    tempFile.writeAsStringSync(contents, flush: true);
    tempFile.renameSync(target.path);
  } catch (_) {
    if (tempFile.existsSync()) {
      try {
        tempFile.deleteSync();
      } catch (_) {}
    }
    rethrow;
  }
}

Future<void> secureWriteFileWithChmodForTesting(
  File target,
  String contents,
  Future<void> Function(String path) chmod,
) => _secureWriteFile(target, contents, restrictPermissions: true, chmod: chmod);

void secureWriteFileSyncWithChmodForTesting(File target, String contents, void Function(String path) chmod) =>
    _secureWriteFileSync(target, contents, restrictPermissions: true, chmod: chmod);

/// Restricts [path] to owner read/write only (`chmod 600`) on POSIX.
/// No-op on Windows. Throws [StateError] if the chmod process fails.
Future<void> chmodOwnerOnly(String path) async {
  if (Platform.isWindows) return;
  final result = await Process.run('chmod', ['600', path]);
  if (result.exitCode != 0) {
    throw StateError(_chmodFailureMessage(path, result));
  }
}

/// Synchronous counterpart to [chmodOwnerOnly].
void chmodOwnerOnlySync(String path) {
  if (Platform.isWindows) return;
  final result = Process.runSync('chmod', ['600', path]);
  if (result.exitCode != 0) {
    throw StateError(_chmodFailureMessage(path, result));
  }
}

String _chmodFailureMessage(String path, ProcessResult result) {
  final stderr = (result.stderr as String? ?? '').trim();
  return 'Failed to chmod 600 $path: ${stderr.isEmpty ? 'chmod exited ${result.exitCode}' : stderr}';
}
