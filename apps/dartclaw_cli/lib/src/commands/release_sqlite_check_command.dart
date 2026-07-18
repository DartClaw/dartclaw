import 'dart:ffi';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/unstable/ffi_bindings.dart' as sqlite_bindings;

typedef _GetModuleHandleExNative = Int32 Function(Uint32 flags, Pointer<Uint16> address, Pointer<Pointer<Void>> module);
typedef _GetModuleHandleExDart = int Function(int flags, Pointer<Uint16> address, Pointer<Pointer<Void>> module);
typedef _GetModuleFileNameNative = Uint32 Function(Pointer<Void> module, Pointer<Uint16> filename, Uint32 size);
typedef _GetModuleFileNameDart = int Function(Pointer<Void> module, Pointer<Uint16> filename, int size);
typedef _MallocNative = Pointer<Void> Function(IntPtr size);
typedef _MallocDart = Pointer<Void> Function(int size);
typedef _FreeNative = Void Function(Pointer<Void> pointer);
typedef _FreeDart = void Function(Pointer<Void> pointer);

final class ReleaseSqliteCheckCommand extends Command<void> {
  final void Function(String) _writeLine;
  final String Function() _sqliteModulePath;

  ReleaseSqliteCheckCommand({void Function(String)? writeLine, String Function()? sqliteModulePath})
    : _writeLine = writeLine ?? stdout.writeln,
      _sqliteModulePath = sqliteModulePath ?? _windowsSqliteModulePath {
    argParser.addOption('expected-module', mandatory: true, help: 'Expected absolute path of the bundled SQLite DLL.');
  }

  @override
  String get name => 'release-sqlite-check';

  @override
  String get description => 'Validate the bundled release SQLite runtime.';

  @override
  bool get hidden => true;

  @override
  bool get takesArguments => false;

  @override
  void run() {
    final expectedModule = argResults!.option('expected-module')!;
    final db = sqlite3.openInMemory();
    try {
      final loadedModule = _sqliteModulePath();
      if (_normalizedWindowsPath(loadedModule) != _normalizedWindowsPath(expectedModule)) {
        throw StateError('SQLite module identity check failed: expected "$expectedModule", loaded "$loadedModule".');
      }

      final options = db.select('PRAGMA compile_options').map((row) => row.values.first as String).toSet();
      if (!options.contains('ENABLE_FTS5')) {
        throw StateError('Bundled SQLite validation failed: loaded module "$loadedModule" lacks ENABLE_FTS5.');
      }

      db.execute('CREATE VIRTUAL TABLE release_fts_probe USING fts5(body)');
      db.execute("INSERT INTO release_fts_probe(body) VALUES ('bundled sqlite')");
      final matches = db.select("SELECT body FROM release_fts_probe WHERE body MATCH 'bundled'");
      if (matches.length != 1 || matches.single['body'] != 'bundled sqlite') {
        throw StateError('Bundled SQLite validation failed: FTS5 MATCH did not return the inserted row.');
      }

      _writeLine('SQLite module: $loadedModule');
      _writeLine('Bundled SQLite FTS5 validation passed.');
    } finally {
      db.close();
    }
  }
}

String _normalizedWindowsPath(String path) => p.normalize(p.absolute(path)).toLowerCase();

String _windowsSqliteModulePath() {
  if (!Platform.isWindows) {
    throw UnsupportedError('SQLite module identity validation is only available on Windows.');
  }

  const fromAddress = 0x00000004;
  const unchangedRefCount = 0x00000002;
  const pathCapacity = 32768;

  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getModuleHandleEx = kernel32.lookupFunction<_GetModuleHandleExNative, _GetModuleHandleExDart>(
    'GetModuleHandleExW',
  );
  final getModuleFileName = kernel32.lookupFunction<_GetModuleFileNameNative, _GetModuleFileNameDart>(
    'GetModuleFileNameW',
  );
  final runtime = DynamicLibrary.open('ucrtbase.dll');
  final malloc = runtime.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = runtime.lookupFunction<_FreeNative, _FreeDart>('free');
  final module = malloc(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
  final filename = malloc(sizeOf<Uint16>() * pathCapacity).cast<Uint16>();
  if (module.address == 0 || filename.address == 0) {
    if (module.address != 0) free(module.cast());
    if (filename.address != 0) free(filename.cast());
    throw StateError('SQLite module identity check failed: unable to allocate a Windows path buffer.');
  }

  try {
    final found = getModuleHandleEx(
      fromAddress | unchangedRefCount,
      sqlite_bindings.addresses.sqlite3_libversion.cast<Uint16>(),
      module,
    );
    if (found == 0) {
      throw StateError('SQLite module identity check failed: sqlite3_libversion has no loaded Windows module.');
    }

    final length = getModuleFileName(module.value, filename, pathCapacity);
    if (length == 0 || length >= pathCapacity) {
      throw StateError('SQLite module identity check failed: Windows did not return the loaded module path.');
    }
    return String.fromCharCodes([for (var i = 0; i < length; i++) (filename + i).value]);
  } finally {
    free(module.cast());
    free(filename.cast());
  }
}
