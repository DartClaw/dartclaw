import 'dart:io';

import 'package:test/test.dart';

void main() {
  final source = File('packages/dartclaw_runtime/lib/src/static/controllers/dc_shell_controller.js').readAsStringSync();

  test('controller overlays IndexedDB drafts and pages remote settled truth', () {
    final shared = File('packages/dartclaw_runtime/lib/src/static/controllers/shared.js').readAsStringSync();
    expect(source, contains('conversationDraftSessionIds()'));
    expect(shared, contains('const db = await openConversationDraftDb()'));
    expect(shared, contains("indexedDB.open('dartclaw-conversation-drafts', 1)"));
    expect(shared, contains("createObjectStore('drafts', { keyPath: 'key' })"));
    expect(source, contains("fetch('/api/inbox?'"));
    expect(source, contains('settled remotely'));
    expect(source, contains('conversation_revision'));
    expect(source, contains('settleInboxRows'));
    expect(source, contains('nextAttentionSessionId'));
    expect(source, contains('missingActiveRow'));
    expect(source, contains('refreshInboxMarkup(values)'));
    expect(source, contains("fetch(location.href, { headers: { accept: 'text/html' } })"));
    expect(source, contains("sourceRef: 'conversation-inbox', recovered: true"));
  });

  test('resize and drawer preserve keyboard focus commands and touch targets', () {
    expect(source, contains('sidebarDefaultWidth = 260'));
    expect(source, contains('sidebarMinWidth = 220'));
    expect(source, contains('sidebarMaxWidth = 420'));
    expect(source, contains("event.key === 'ArrowLeft'"));
    expect(source, contains("event.key === 'ArrowRight'"));
    expect(source, contains("event.key === 'Home'"));
    expect(source, contains('setSidebarOpen(false)'));
  });
}
