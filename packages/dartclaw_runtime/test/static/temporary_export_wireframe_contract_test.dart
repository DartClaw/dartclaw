import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('temporary and export wireframes expose every reviewable state', () {
    final chat = File('dev/bundle/docs/wireframes/chat-conversation-cards.html').readAsStringSync();
    final archive = File('dev/bundle/docs/wireframes/archive-session.html').readAsStringSync();
    for (final state in [
      'temporary-live',
      'temporary-ending',
      'temporary-end-failed',
      'export-confirmation',
      'draft-loss-warning',
    ]) {
      expect(chat, contains('data-fixture-state="$state"'), reason: state);
    }
    expect(chat, contains('aria-labelledby="temporary-export-title"'));
    expect(chat, contains('aria-describedby="temporary-export-detail"'));
    expect(archive, contains('data-fixture-state="export-result"'));
    expect(archive, contains('Attachment manifest'));
    expect(archive, contains('unavailable'));
  });
}
