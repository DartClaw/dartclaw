import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('all three wireframes carry the integrated effective-context states', () {
    final chat = File('dev/bundle/docs/wireframes/chat-conversation-cards.html').readAsStringSync();
    for (final id in const [
      'effective-context-summary',
      'effective-context-workspace',
      'effective-context-current',
      'effective-context-next',
      'effective-context-dialog',
      'effective-context-continuity',
      'effective-context-source',
      'effective-context-unavailable',
      'effective-context-rejection',
    ]) {
      expect(chat, contains('id="$id"'), reason: id);
    }

    final info = File('dev/bundle/docs/wireframes/session-info-panel.html').readAsStringSync();
    for (final id in const [
      'session-effective-context',
      'session-context-owner',
      'session-context-project',
      'session-context-telemetry',
      'session-context-behavior',
      'session-context-memory',
      'session-title-precedence',
    ]) {
      expect(info, contains('id="$id"'), reason: id);
    }

    final newChat = File('dev/bundle/docs/wireframes/new-session.html').readAsStringSync();
    expect(newChat, contains('id="new-chat-effective-context"'));
    expect(newChat, contains('id="new-chat-owner"'));
    expect(newChat, contains('data-identicon-id="dartclaw"'));
    expect(newChat, isNot(contains('workspace picker')));
    expect(newChat, isNot(contains('persona picker')));
  });
}
