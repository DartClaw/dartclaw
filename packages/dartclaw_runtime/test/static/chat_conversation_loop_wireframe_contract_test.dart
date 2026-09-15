import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('conversation composer wireframes expose labelled recovery and control states', () async {
    final sources = {
      'chat-composer': File(await resolveWorkspacePath('dev', 'bundle', 'docs/wireframes/chat-composer.html'))
          .readAsStringSync(),
      'chat-conversation-cards': File(
        await resolveWorkspacePath('dev', 'bundle', 'docs/wireframes/chat-conversation-cards.html'),
      ).readAsStringSync(),
    };

    for (final MapEntry(key: name, value: source) in sources.entries) {
      expect(source, contains('<!DOCTYPE html>'), reason: '$name must remain a complete browser fixture');
      expect(RegExp(r'<label[^>]+for="([^"]+)"').allMatches(source), isNotEmpty, reason: '$name needs a label');
      for (final label in RegExp(r'<label[^>]+for="([^"]+)"').allMatches(source)) {
        expect(source, contains('id="${label.group(1)}"'), reason: '$name label target is missing');
      }
      for (final state in const ['submitting', 'queued', 'held', 'stopping', 'reconnect', 'unsaved', 'upload-failed']) {
        expect(source, contains('data-conversation-state="$state"'), reason: '$name omits $state');
      }
      expect(source, contains('Saved on this device'), reason: '$name omits the durable save state');
      expect(source, contains('aria-label="Queue message"'), reason: '$name queue action is not named');
      expect(source, contains('aria-label="Steer: stop the current turn, then send this follow-up"'));
      expect(source, contains('aria-label="Stop current turn"'));
      expect(source, contains('Send next queued message'));
      if (name == 'chat-composer') {
        expect(source, contains('44px'), reason: '$name must retain the minimum action target token');
      } else {
        expect(
          source,
          contains('../../../design-system/components.css'),
          reason: '$name must use canonical action targets',
        );
      }
    }
  });
}
