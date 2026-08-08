import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final shared = controllerAsset('shared.js');

  test('sidebar title sync touches only rows that publish an explicit hook', () async {
    await expectNodeHarness(_titleSyncHarness, [shared.path]);
  });

  test('automatic and manual renames use the shared title sync seam', () {
    final chat = controllerAsset('dc_chat_controller.js').readAsStringSync();
    final shell = controllerAsset('dc_shell_controller.js').readAsStringSync();

    expect(chat, contains('syncSidebarSessionTitle(this.sessionId, title)'));
    expect(shell, contains('syncSidebarSessionTitle(sessionId, newTitle)'));
    expect(shell, contains('delete chatArea.dataset.newChatDraft'));
  });
}

const _titleSyncHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const mutableTitle = { dataset: { sessionTitleId: 'chat-1' }, textContent: 'Untitled draft' };
const agentTitle = { textContent: 'Agent' };
globalThis.window = { dartclaw: {} };
globalThis.document = {
  querySelectorAll(selector) {
    return selector === '[data-session-title-id]' ? [mutableTitle] : [];
  },
};

const source = await readFile(process.argv[1], 'utf8');
const shared = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
shared.syncSidebarSessionTitle('main', 'What is 42?');
assert(agentTitle.textContent === 'Agent', 'workspace identity was mutated without a title-sync hook');
shared.syncSidebarSessionTitle('chat-1', 'What is 42?');
assert(mutableTitle.textContent === 'What is 42?', 'mutable chat title was not synchronized');
''';
