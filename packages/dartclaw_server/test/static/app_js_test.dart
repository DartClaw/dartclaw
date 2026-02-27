import 'dart:io';

import 'package:test/test.dart';

void main() {
  final scriptPath =
      File('packages/dartclaw_server/lib/src/static/app.js').existsSync()
          ? 'packages/dartclaw_server/lib/src/static/app.js'
          : 'lib/src/static/app.js';

  group('app.js lifecycle safeguards', () {
    test('handles failed HTMX requests by re-enabling input', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('htmx:afterRequest'));
      expect(source, contains('if (event.detail.successful)'));
      expect(source, contains('enableInput();'));
    });

    test('only starts SSE stream for #sse-container swaps', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains("target.id !== 'sse-container'"));
    });

    test('guards against duplicate EventSource for same stream URL', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('activeStreamUrl === url'));
      expect(source, contains('closeActiveStream();'));
    });

    test('supports both message and error keys in SSE error payload', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('payload.message || payload.error ||'));
    });

    test('JS contains create-session handler', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('data-action="create-session"'));
    });

    test('JS contains delete-session handler', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('data-action="delete-session"'));
    });

    test('JS contains confirm() call for delete confirmation', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('confirm('));
    });

    test('JS contains inline rename handling', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('initInlineRename'));
    });

    test('JS contains auto-title logic', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('hasTitle'));
    });

    test('manual rename marks session as titled to prevent auto-title overwrite', () {
      final source = File(scriptPath).readAsStringSync();
      final matches = RegExp(r"dataset\.hasTitle\s*=\s*'true'").allMatches(source).length;
      expect(matches, greaterThanOrEqualTo(2));
    });
  });
}
