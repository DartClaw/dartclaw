import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show chmodOwnerOnly, chmodOwnerOnlySync, secureWriteFile, secureWriteFileSync;
import 'package:dartclaw_core/src/storage/atomic_write.dart' as atomic_write;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('secure_file_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  void expectOwnerOnly(File file) {
    if (Platform.isWindows) return; // POSIX permission model only.
    final mode = file.statSync().mode & 0x1ff;
    expect(mode.toRadixString(8), '600');
  }

  void expectNoTempLeftBehind(Directory dir, File target) {
    final leftovers = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path != target.path && f.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty, reason: 'atomic rename should leave no temp file behind');
  }

  group('secureWriteFile', () {
    test('writes contents and restricts to owner-only', () async {
      final target = File('${tempDir.path}/secret');
      await secureWriteFile(target, 'token-value');

      expect(target.readAsStringSync(), 'token-value');
      expectOwnerOnly(target);
      expectNoTempLeftBehind(tempDir, target);
    });

    test('overwrites an existing file atomically', () async {
      final target = File('${tempDir.path}/secret');
      await secureWriteFile(target, 'old');
      await secureWriteFile(target, 'new');

      expect(target.readAsStringSync(), 'new');
      expectNoTempLeftBehind(tempDir, target);
    });

    test('restrictPermissions:false skips the chmod step', () async {
      final target = File('${tempDir.path}/secret');
      await secureWriteFile(target, 'data', restrictPermissions: false);

      expect(target.readAsStringSync(), 'data');
      expectNoTempLeftBehind(tempDir, target);
    });

    test('tightens temp file before writing secret contents', () async {
      final target = File('${tempDir.path}/secret');
      var chmodSawEmptyTemp = false;

      await atomic_write.secureWriteFileWithChmodForTesting(target, 'token-value', (path) async {
        final temp = File(path);
        expect(temp.existsSync(), isTrue);
        expect(temp.readAsStringSync(), isEmpty);
        chmodSawEmptyTemp = true;
        await chmodOwnerOnly(path);
      });

      expect(chmodSawEmptyTemp, isTrue);
      expect(target.readAsStringSync(), 'token-value');
      expectOwnerOnly(target);
      expectNoTempLeftBehind(tempDir, target);
    });

    test('does not leave secret contents behind when temp chmod fails', () async {
      final target = File('${tempDir.path}/secret');

      await expectLater(
        atomic_write.secureWriteFileWithChmodForTesting(target, 'token-value', (_) async {
          throw StateError('chmod failed');
        }),
        throwsStateError,
      );

      expect(target.existsSync(), isFalse);
      expectNoTempLeftBehind(tempDir, target);
    });
  });

  group('secureWriteFileSync', () {
    test('writes contents and restricts to owner-only', () {
      final target = File('${tempDir.path}/secret-sync');
      secureWriteFileSync(target, 'token-value');

      expect(target.readAsStringSync(), 'token-value');
      expectOwnerOnly(target);
      expectNoTempLeftBehind(tempDir, target);
    });

    test('tightens temp file before writing secret contents', () {
      final target = File('${tempDir.path}/secret-sync');
      var chmodSawEmptyTemp = false;

      atomic_write.secureWriteFileSyncWithChmodForTesting(target, 'token-value', (path) {
        final temp = File(path);
        expect(temp.existsSync(), isTrue);
        expect(temp.readAsStringSync(), isEmpty);
        chmodSawEmptyTemp = true;
        chmodOwnerOnlySync(path);
      });

      expect(chmodSawEmptyTemp, isTrue);
      expect(target.readAsStringSync(), 'token-value');
      expectOwnerOnly(target);
      expectNoTempLeftBehind(tempDir, target);
    });
  });

  group('chmodOwnerOnly', () {
    test('async restricts an existing file to owner-only', () async {
      final target = File('${tempDir.path}/plain')..writeAsStringSync('x');
      await chmodOwnerOnly(target.path);
      expectOwnerOnly(target);
    });

    test('sync restricts an existing file to owner-only', () {
      final target = File('${tempDir.path}/plain-sync')..writeAsStringSync('x');
      chmodOwnerOnlySync(target.path);
      expectOwnerOnly(target);
    });
  });
}
