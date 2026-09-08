import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String currentPath;
  late String legacyPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('authoritative-store-adoption-');
    currentPath = p.join(tempDir.path, 'dartclaw.db');
    legacyPath = p.join(tempDir.path, 'tasks.db');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('fresh directory and orphan legacy sidecars are left alone', () async {
    await adoptLegacyAuthoritativeStore(currentPath);
    expect(tempDir.listSync(), isEmpty);

    File('$legacyPath-wal').writeAsStringSync('orphan wal');
    File('$legacyPath-shm').writeAsStringSync('orphan shm');
    final before = _snapshot(tempDir);

    await adoptLegacyAuthoritativeStore(currentPath);

    expect(_snapshot(tempDir), before);
    expect(File(currentPath).existsSync(), isFalse);
  });

  test('clean legacy store is renamed byte-for-byte and a second call is a no-op', () async {
    final database = sqlite3.open(legacyPath);
    database
      ..execute('CREATE TABLE tasks (id TEXT PRIMARY KEY)')
      ..execute("INSERT INTO tasks VALUES ('task-1')");
    database.close();
    final before = File(legacyPath).readAsBytesSync();

    await adoptLegacyAuthoritativeStore(currentPath);

    expect(File(legacyPath).existsSync(), isFalse);
    expect(File(currentPath).readAsBytesSync(), before);
    final once = _snapshot(tempDir);
    await adoptLegacyAuthoritativeStore(currentPath);
    expect(_snapshot(tempDir), once);
  });

  test('WAL-resident committed content survives adoption and spent sidecars are removed', () async {
    final source = Directory(p.join(tempDir.path, 'source'))..createSync();
    final fixture = Directory(p.join(tempDir.path, 'fixture'))..createSync();
    currentPath = p.join(fixture.path, 'dartclaw.db');
    legacyPath = p.join(fixture.path, 'tasks.db');
    final sourcePath = p.join(source.path, 'tasks.db');
    final writer = sqlite3.open(sourcePath);
    writer
      ..execute('PRAGMA journal_mode=WAL')
      ..execute('PRAGMA wal_autocheckpoint=0')
      ..execute('CREATE TABLE tasks (id TEXT PRIMARY KEY)')
      ..execute("INSERT INTO tasks VALUES ('wal-task')");
    for (final suffix in const ['', '-wal', '-shm']) {
      File('$sourcePath$suffix').copySync('$legacyPath$suffix');
    }
    writer.close();

    await adoptLegacyAuthoritativeStore(currentPath);

    expect(File(legacyPath).existsSync(), isFalse);
    expect(File('$legacyPath-wal').existsSync(), isFalse);
    expect(File('$legacyPath-shm').existsSync(), isFalse);
    final adopted = sqlite3.open(currentPath, mode: OpenMode.readOnly);
    expect(adopted.select('SELECT id FROM tasks').single['id'], 'wal-task');
    adopted.close();
  });

  test('both filenames refuse with sizes and recovery guidance without changing bytes', () async {
    File(currentPath).writeAsBytesSync([1, 2, 3]);
    File(legacyPath).writeAsBytesSync([4, 5]);
    final before = _snapshot(tempDir);

    await expectLater(
      adoptLegacyAuthoritativeStore(currentPath),
      throwsA(
        isA<AuthoritativeStoreAdoptionException>()
            .having((error) => error.toString(), 'message', contains('dartclaw.db'))
            .having((error) => error.toString(), 'message', contains('tasks.db'))
            .having((error) => error.toString(), 'message', contains('3 bytes'))
            .having((error) => error.toString(), 'message', contains('2 bytes'))
            .having((error) => error.toString().toLowerCase(), 'message', contains('ambiguous'))
            .having((error) => error.toString().toLowerCase(), 'message', contains('keep'))
            .having((error) => error.toString().toLowerCase(), 'message', contains('remove')),
      ),
    );
    expect(_snapshot(tempDir), before);
  });

  test('busy checkpoint refuses with the legacy store unchanged', () async {
    final writer = sqlite3.open(legacyPath);
    writer
      ..execute('PRAGMA journal_mode=WAL')
      ..execute('PRAGMA wal_autocheckpoint=0')
      ..execute('CREATE TABLE tasks (id TEXT PRIMARY KEY)')
      ..execute("INSERT INTO tasks VALUES ('first')")
      ..execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final reader = sqlite3.open(legacyPath);
    reader
      ..execute('BEGIN')
      ..select('SELECT * FROM tasks');
    writer.execute("INSERT INTO tasks VALUES ('held-in-wal')");
    final mainBefore = File(legacyPath).readAsBytesSync();
    final walBefore = File('$legacyPath-wal').readAsBytesSync();
    addTearDown(() {
      reader
        ..execute('ROLLBACK')
        ..close();
      writer.close();
    });

    await expectLater(
      adoptLegacyAuthoritativeStore(currentPath),
      throwsA(
        isA<AuthoritativeStoreAdoptionException>().having(
          (error) => error.toString().toLowerCase(),
          'message',
          contains('in use'),
        ),
      ),
    );
    expect(File(currentPath).existsSync(), isFalse);
    expect(File(legacyPath).readAsBytesSync(), mainBefore);
    expect(File('$legacyPath-wal').readAsBytesSync(), walBefore);
    expect(File('$legacyPath-shm').existsSync(), isTrue);
  });

  test('rename failure reports the OS error and leaves the legacy store unchanged', () async {
    if (Platform.isWindows || Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
      markTestSkipped('POSIX permissions require a non-root process');
      return;
    }
    _writeStore(legacyPath, populated: true);
    final before = File(legacyPath).readAsBytesSync();
    Process.runSync('chmod', ['500', tempDir.path]);
    try {
      await expectLater(
        adoptLegacyAuthoritativeStore(currentPath),
        throwsA(
          isA<AuthoritativeStoreAdoptionException>()
              .having((error) => error.cause, 'cause', isA<FileSystemException>())
              .having((error) => error.toString(), 'message', contains('Could not rename')),
        ),
      );
      expect(File(currentPath).existsSync(), isFalse);
      expect(File(legacyPath).readAsBytesSync(), before);
    } finally {
      Process.runSync('chmod', ['700', tempDir.path]);
    }
  });

  test('WAL data remains readable after rename refusal and can be adopted on retry', () async {
    if (Platform.isWindows || Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
      markTestSkipped('POSIX permissions require a non-root process');
      return;
    }
    final sourcePath = p.join(tempDir.path, 'source.db');
    final writer = sqlite3.open(sourcePath);
    writer
      ..execute('PRAGMA journal_mode=WAL')
      ..execute('PRAGMA wal_autocheckpoint=0')
      ..execute('CREATE TABLE tasks (id TEXT PRIMARY KEY)')
      ..execute("INSERT INTO tasks VALUES ('committed-in-wal')");
    for (final suffix in const ['', '-wal', '-shm']) {
      File('$sourcePath$suffix').copySync('$legacyPath$suffix');
    }
    writer.close();
    File(sourcePath).deleteSync();
    expect(File('$legacyPath-wal').lengthSync(), greaterThan(0));

    expect(Process.runSync('chmod', ['500', tempDir.path]).exitCode, 0);
    try {
      await expectLater(
        adoptLegacyAuthoritativeStore(currentPath),
        throwsA(
          isA<AuthoritativeStoreAdoptionException>()
              .having((error) => error.cause, 'cause', isA<FileSystemException>())
              .having((error) => error.toString(), 'message', contains('Could not rename')),
        ),
      );
      expect(File(currentPath).existsSync(), isFalse);
      expect(File(legacyPath).existsSync(), isTrue);
      final recovered = sqlite3.open(legacyPath, mode: OpenMode.readOnly);
      try {
        expect(recovered.select('SELECT id FROM tasks').single['id'], 'committed-in-wal');
      } finally {
        recovered.close();
      }
    } finally {
      expect(Process.runSync('chmod', ['700', tempDir.path]).exitCode, 0);
    }

    await adoptLegacyAuthoritativeStore(currentPath);
    expect(File(legacyPath).existsSync(), isFalse);
    expect(File('$legacyPath-wal').existsSync(), isFalse);
    expect(File('$legacyPath-shm').existsSync(), isFalse);
    final adopted = sqlite3.open(currentPath, mode: OpenMode.readOnly);
    try {
      expect(adopted.select('SELECT id FROM tasks').single['id'], 'committed-in-wal');
    } finally {
      adopted.close();
    }
  });

  test('probe reports absent, current, legacy, empty, ambiguous, and unreadable states read-only', () async {
    expect(await probeAuthoritativeStore(currentPath), isA<AuthoritativeStoreAbsent>());
    expect(tempDir.listSync(), isEmpty);

    _writeStore(currentPath, populated: false);
    var before = _snapshot(tempDir);
    var result = await probeAuthoritativeStore(currentPath);
    expect(
      result,
      isA<AuthoritativeStorePresent>()
          .having((probe) => probe.path, 'path', currentPath)
          .having((probe) => probe.content, 'content', AuthoritativeStoreContentState.empty),
    );
    expect(_snapshot(tempDir), before);

    File(currentPath).deleteSync();
    _writeStore(legacyPath, populated: true);
    before = _snapshot(tempDir);
    result = await probeAuthoritativeStore(currentPath);
    expect(
      result,
      isA<AuthoritativeStorePresent>()
          .having((probe) => probe.path, 'path', legacyPath)
          .having((probe) => probe.content, 'content', AuthoritativeStoreContentState.nonEmpty),
    );
    expect(_snapshot(tempDir), before);

    _writeStore(currentPath, populated: true);
    before = _snapshot(tempDir);
    expect(await probeAuthoritativeStore(currentPath), isA<AuthoritativeStoreAmbiguous>());
    expect(_snapshot(tempDir), before);

    File(legacyPath).deleteSync();
    File(currentPath).writeAsStringSync('not sqlite');
    before = _snapshot(tempDir);
    result = await probeAuthoritativeStore(currentPath);
    expect(
      result,
      isA<AuthoritativeStorePresent>()
          .having((probe) => probe.content, 'content', AuthoritativeStoreContentState.couldNotVerify)
          .having((probe) => probe.error, 'error', isNotNull),
    );
    expect(_snapshot(tempDir), before);
  });

  test('two concurrent adopters converge on one current store', () async {
    _writeStore(legacyPath, populated: true);

    await Future.wait([
      Isolate.run(() => adoptLegacyAuthoritativeStore(currentPath)),
      Isolate.run(() => adoptLegacyAuthoritativeStore(currentPath)),
    ]);

    expect(File(currentPath).existsSync(), isTrue);
    expect(File(legacyPath).existsSync(), isFalse);
    expect(tempDir.listSync().whereType<File>().map((file) => p.basename(file.path)), ['dartclaw.db']);
  });
}

void _writeStore(String path, {required bool populated}) {
  final database = sqlite3.open(path);
  database.execute('CREATE TABLE tasks (id TEXT PRIMARY KEY)');
  if (populated) database.execute("INSERT INTO tasks VALUES ('task-1')");
  database.close();
}

Map<String, List<int>> _snapshot(Directory directory) {
  final entries = directory.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
  return {for (final file in entries) p.relative(file.path, from: directory.path): file.readAsBytesSync()};
}
