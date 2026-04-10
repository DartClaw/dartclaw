import 'dart:io';

import 'package:dartclaw_cli/src/commands/init/setup_preflight.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('setup_preflight_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('SetupPreflight', () {
    test('passes when all providers resolve and target path is writable', () async {
      final result = await SetupPreflight.run(
        providers: const ['claude', 'codex'],
        port: _freePort(),
        instanceDir: tempDir.path,
        runProcess: (exe, args) async => ProcessResult(0, 0, '$exe/1.0', ''),
      );

      expect(result.passed, isTrue);
      expect(result.errors, isEmpty);
    });

    test('fails when a provider binary returns non-zero', () async {
      final result = await SetupPreflight.run(
        providers: const ['claude'],
        port: _freePort(),
        instanceDir: tempDir.path,
        runProcess: (exe, args) async => ProcessResult(0, 1, '', 'error'),
      );

      expect(result.passed, isFalse);
      expect(result.errors.single, contains('non-zero'));
    });

    test('fails when any provider binary is missing', () async {
      final result = await SetupPreflight.run(
        providers: const ['claude', 'codex'],
        port: _freePort(),
        instanceDir: tempDir.path,
        runProcess: (exe, args) async {
          if (exe == 'codex') {
            throw ProcessException(exe, args, 'not found');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(result.passed, isFalse);
      expect(result.errors.join('\n'), contains("Provider binary 'codex'"));
    });

    test('fails when port is already in use', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final result = await SetupPreflight.run(
        providers: const ['claude'],
        port: server.port,
        instanceDir: tempDir.path,
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
      );

      expect(result.passed, isFalse);
      expect(result.errors.join('\n'), contains('already in use'));
    });

    test('fails when instance path exists as a file', () async {
      final filePath = '${tempDir.path}/not-a-dir';
      File(filePath).writeAsStringSync('x');

      final result = await SetupPreflight.run(
        providers: const ['claude'],
        port: _freePort(),
        instanceDir: filePath,
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
      );

      expect(result.passed, isFalse);
      expect(result.errors.join('\n'), contains('not a directory'));
    });
  });
}

int _freePort() => 49876;
