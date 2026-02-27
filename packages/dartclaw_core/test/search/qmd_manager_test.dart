import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');
ProcessResult _fail([String stderr = 'error']) => ProcessResult(0, 1, '', stderr);

void main() {
  late List<(String, List<String>, String?)> calls;

  setUp(() {
    calls = [];
  });

  Future<ProcessResult> fakeRunner(
    String exe,
    List<String> args, {
    String? workingDirectory,
  }) async {
    calls.add((exe, args, workingDirectory));
    if (args.contains('--version')) return _ok('qmd 1.0.0');
    if (args.contains('update')) return _ok();
    if (args.contains('embed')) return _ok();
    if (args.contains('collection')) return _ok();
    if (args.contains('mcp')) return _ok();
    return _ok();
  }

  group('QmdManager', () {
    test('isAvailable returns true when binary exists', () async {
      final mgr = QmdManager(commandRunner: fakeRunner);
      expect(await mgr.isAvailable(), isTrue);
    });

    test('isAvailable returns false when binary missing', () async {
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) async => _fail(),
      );
      expect(await mgr.isAvailable(), isFalse);
    });

    test('triggerIndex runs update then embed', () async {
      final mgr = QmdManager(commandRunner: fakeRunner, workspaceDir: '/tmp');
      await mgr.triggerIndex();

      expect(calls, hasLength(2));
      expect(calls[0].$2, contains('update'));
      expect(calls[1].$2, contains('embed'));
      // Both use workingDirectory
      expect(calls[0].$3, '/tmp');
      expect(calls[1].$3, '/tmp');
    });

    test('setupCollection runs correct command', () async {
      final mgr = QmdManager(commandRunner: fakeRunner);
      await mgr.setupCollection('/home/user/.dartclaw/workspace');

      expect(calls, hasLength(1));
      expect(calls[0].$2, contains('collection'));
      expect(calls[0].$2, contains('add'));
      expect(calls[0].$2, contains('/home/user/.dartclaw/workspace'));
      expect(calls[0].$2, contains('--name'));
      expect(calls[0].$2, contains('memory'));
    });

    test('baseUrl reflects host and port', () {
      final mgr = QmdManager(host: '127.0.0.1', port: 9090);
      expect(mgr.baseUrl, 'http://127.0.0.1:9090');
    });
  });
}
