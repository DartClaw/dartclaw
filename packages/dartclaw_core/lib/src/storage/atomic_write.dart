import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _tempSuffixRand = Random.secure();

/// Atomically writes [value]; last writer wins without caller locking.
Future<void> atomicWriteJson(File f, Object value) => secureWriteFile(f, jsonEncode(value), restrictPermissions: false);
String _tempSuffix() =>
    List.generate(4, (_) => _tempSuffixRand.nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0')).join();

/// Atomically writes [contents], preserving an existing regular target's POSIX permissions.
Future<void> secureWriteFile(File target, String contents, {bool restrictPermissions = true}) =>
    _secureWriteFile(target, contents, restrictPermissions: restrictPermissions, chmod: chmodOwnerOnly);
Future<void> _secureWriteFile(
  File target,
  String contents, {
  required bool restrictPermissions,
  required Future<void> Function(String path) chmod,
}) async {
  final tempFile = File('${target.path}.${_tempSuffix()}.tmp');
  RandomAccessFile? handle;
  try {
    handle = await tempFile.open(mode: FileMode.writeOnly);
    final mode = _replacementMode(target, restrictPermissions);
    final tempMode = Platform.isWindows ? mode : (await tempFile.stat()).mode & 0x1ff;
    if (mode == 0x180 && tempMode != mode) await chmod(tempFile.path);
    if (mode != null && mode != 0x180 && tempMode != mode) await _chmodMode(tempFile.path, mode);
    await handle.writeString(contents);
    await handle.flush();
    await handle.close();
    handle = null;
    await tempFile.rename(target.path);
  } catch (_) {
    try {
      await handle?.close();
    } catch (_) {}
    _deleteTempSync(tempFile);
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
  RandomAccessFile? handle;
  try {
    handle = tempFile.openSync(mode: FileMode.writeOnly);
    final mode = _replacementMode(target, restrictPermissions);
    final tempMode = Platform.isWindows ? mode : tempFile.statSync().mode & 0x1ff;
    if (mode == 0x180 && tempMode != mode) chmod(tempFile.path);
    if (mode != null && mode != 0x180 && tempMode != mode) _chmodModeSync(tempFile.path, mode);
    handle.writeStringSync(contents);
    handle.flushSync();
    handle.closeSync();
    handle = null;
    tempFile.renameSync(target.path);
  } catch (_) {
    try {
      handle?.closeSync();
    } catch (_) {}
    _deleteTempSync(tempFile);
    rethrow;
  }
}

int? _replacementMode(File target, bool restrictPermissions) {
  if (restrictPermissions || Platform.isWindows) return restrictPermissions ? 0x180 : null;
  if (FileSystemEntity.typeSync(target.path, followLinks: false) != FileSystemEntityType.file) return null;
  return target.statSync().mode & 0x1ff;
}

void _deleteTempSync(File tempFile) {
  try {
    tempFile.deleteSync();
  } catch (_) {}
}

Future<void> secureWriteFileWithChmodForTesting(
  File target,
  String contents,
  Future<void> Function(String path) chmod,
) => _secureWriteFile(target, contents, restrictPermissions: true, chmod: chmod);
void secureWriteFileSyncWithChmodForTesting(File target, String contents, void Function(String path) chmod) =>
    _secureWriteFileSync(target, contents, restrictPermissions: true, chmod: chmod);

/// Restricts [path] to mode 600 on POSIX; no-op on Windows.
Future<void> chmodOwnerOnly(String path) => Platform.isWindows ? Future.value() : _chmodMode(path, 0x180);

/// Synchronous counterpart to [chmodOwnerOnly].
void chmodOwnerOnlySync(String path) => _chmodModeSync(path, Platform.isWindows ? null : 0x180);

/// Restricts the directory at [path] to mode 700 on POSIX; no-op on Windows.
///
/// Directories need the execute bit to stay traversable, so [chmodOwnerOnlySync]
/// (mode 600) must not be used on one.
void chmodOwnerOnlyDirSync(String path) => _chmodModeSync(path, Platform.isWindows ? null : 0x1c0);

Future<void> _chmodMode(String path, int mode) async {
  final modeText = mode.toRadixString(8).padLeft(3, '0');
  final result = await Process.run('chmod', [modeText, path]);
  if (result.exitCode != 0) throw StateError(_chmodFailureMessage(path, modeText, result));
}

void _chmodModeSync(String path, int? mode) {
  if (mode == null) return;
  final modeText = mode.toRadixString(8).padLeft(3, '0');
  final result = Process.runSync('chmod', [modeText, path]);
  if (result.exitCode != 0) throw StateError(_chmodFailureMessage(path, modeText, result));
}

String _chmodFailureMessage(String path, String mode, ProcessResult result) =>
    'Failed to chmod $mode $path: ${('${result.stderr}').trim().isEmpty ? 'chmod exited ${result.exitCode}' : '${result.stderr}'.trim()}';
