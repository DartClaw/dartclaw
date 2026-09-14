import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('attention controller preserves exact durable identity and focus', () async {
    final source = (await controllerAsset('dc_shell_controller.js')).readAsStringSync();
    for (final marker in ['event_id', 'session_id', 'attempt_id', 'turn_id', 'request_id', 'conversation_revision']) {
      expect(source, contains(marker));
    }
    expect(source, contains("panel.querySelector('a,button')?.focus()"));
    expect(source, contains("sourceRef: 'attention-feed'"));
  });
}
