import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('keyed poll failures persist per source and preserve turn cadence', () async {
    final shared = (await controllerAsset('shared.js')).readAsStringSync();
    final chat = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(shared, contains('const persistentToasts = new Map()'));
    expect(shared, contains('options.recovered && sourceRef'));
    expect(chat, contains("sourceRef: 'chat-turn-status'"));
    expect(chat, contains('setInterval(poll, 2500)'));
  });
}
