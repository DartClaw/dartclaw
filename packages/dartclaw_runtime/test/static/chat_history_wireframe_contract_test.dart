import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('history wireframes expose referenceable states and accessible relationships', () {
    final conversation = File('dev/bundle/docs/wireframes/chat-conversation-cards.html').readAsStringSync();
    final guard = File('dev/bundle/docs/wireframes/guard-block-chat.html').readAsStringSync();

    for (final source in [conversation, guard]) {
      expect(source, contains('<!DOCTYPE html>'));
      expect(source, contains('data-history-viewport="stable-anchor"'));
      expect(source, contains('data-phone-state="375 390 768"'));
      expect(source, contains('data-desktop-state="1440"'));
      for (final message in RegExp(r'data-message-id="([^"]+)"').allMatches(source)) {
        expect(source, contains('id="message-${message.group(1)}"'));
      }
      for (final controls in RegExp(r'aria-controls="([^"]+)"').allMatches(source)) {
        expect(source, contains('id="${controls.group(1)}"'));
      }
    }

    for (final state in const [
      'partial-retained',
      'approval-pending',
      'approval-resolved',
      'target-unavailable',
      'linked-branch',
      'new-activity',
    ]) {
      expect(conversation, contains('data-history-state="$state"'), reason: state);
    }
    for (final state in const ['succeeded', 'running', 'blocked']) {
      expect(conversation, contains('data-state="$state"'), reason: state);
    }
    expect(conversation, contains('data-retained-output="redacted-truncated"'));
    expect(conversation, contains('data-approval-request-id="approval-release-push"'));
    expect(conversation, contains('data-approval-attempt-id="attempt-release"'));
    expect(conversation, contains('data-approval-turn-id="turn-release"'));
    expect(conversation, contains('Approve exact request'));
    expect(conversation, contains('aria-labelledby="approval-release-title"'));
    expect(conversation, contains('data-history-focus'));

    expect(guard, contains('data-guard-kind="hard-block"'));
    expect(guard, contains('data-history-state="non-approvable"'));
    expect(guard, isNot(contains('data-approval-decision')));
    expect(guard, isNot(contains('data-approval-request-id')));
  });
}
