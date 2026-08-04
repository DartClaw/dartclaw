import 'dart:io';

import 'package:test/test.dart';

void main() {
  final baseDir = Directory('packages/dartclaw_server/lib/src/static/controllers').existsSync()
      ? 'packages/dartclaw_server/lib/src/static/controllers'
      : 'lib/src/static/controllers';

  test('sidebar title sync touches only rows that publish an explicit hook', () async {
    ProcessResult result;
    try {
      result = await Process.run('node', ['--input-type=module', '--eval', _titleSyncHarness, '$baseDir/shared.js']);
    } on ProcessException catch (error) {
      fail('Node.js is required for controller tests: $error');
    }

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });

  test('automatic and manual renames use the shared title sync seam', () {
    final chat = File('$baseDir/dc_chat_controller.js').readAsStringSync();
    final shell = File('$baseDir/dc_shell_controller.js').readAsStringSync();

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
