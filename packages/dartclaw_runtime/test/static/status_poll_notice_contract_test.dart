import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('keyed poll failures persist per source and preserve turn cadence', () {
    final shared = File('packages/dartclaw_runtime/lib/src/static/controllers/shared.js').readAsStringSync();
    final chat = File('packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js').readAsStringSync();
    expect(shared, contains('const persistentToasts = new Map()'));
    expect(shared, contains('options.recovered && sourceRef'));
    expect(chat, contains("sourceRef: 'chat-turn-status'"));
    expect(chat, contains('setInterval(poll, 2500)'));
  });
}
