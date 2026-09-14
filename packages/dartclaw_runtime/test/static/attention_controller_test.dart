import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('attention controller preserves exact durable identity and focus', () {
    final source = File('packages/dartclaw_runtime/lib/src/static/controllers/dc_shell_controller.js')
        .readAsStringSync();
    for (final marker in ['event_id', 'session_id', 'attempt_id', 'turn_id', 'request_id', 'conversation_revision']) {
      expect(source, contains(marker));
    }
    expect(source, contains("panel.querySelector('a,button')?.focus()"));
    expect(source, contains("sourceRef: 'attention-feed'"));
  });
}
