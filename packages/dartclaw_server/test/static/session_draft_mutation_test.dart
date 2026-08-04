import 'dart:io';

import 'package:test/test.dart';

void main() {
  final shared = File('packages/dartclaw_server/lib/src/static/controllers/shared.js').existsSync()
      ? File('packages/dartclaw_server/lib/src/static/controllers/shared.js')
      : File('lib/src/static/controllers/shared.js');

  test('overlapping draft mutations complete only after the final mutation', () async {
    ProcessResult result;
    try {
      result = await Process.run('node', [
        '--input-type=module',
        '--eval',
        _draftMutationHarness,
        shared.absolute.uri.toString(),
      ]);
    } on ProcessException catch (error) {
      fail('Node.js is required for controller tests: $error');
    }

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });
}

const _draftMutationHarness = r'''
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const chatArea = { dataset: { sessionId: 'session-1', newChatDraft: 'true' } };
let completionEvents = 0;
globalThis.CustomEvent = class CustomEvent { constructor(type) { this.type = type; } };
globalThis.window = { location: { search: '' } };
globalThis.document = {
  querySelector(selector) { return selector === '.chat-area' ? chatArea : null; },
  dispatchEvent(event) {
    if (event.type === 'dartclaw:session-draft-mutation-complete') completionEvents += 1;
  },
};

const shared = await import(process.argv[1]);
shared.beginSessionDraftMutation('session-1');
shared.beginSessionDraftMutation('session-1');
assert(chatArea.dataset.sessionMutationPending === '2', 'overlapping begins were not counted');
assert(!('newChatDraft' in chatArea.dataset), 'mutation begin left the draft reusable');

shared.endSessionDraftMutation('session-1');
assert(chatArea.dataset.sessionMutationPending === '1', 'first completion cleared the overlapping mutation');
assert(completionEvents === 0, 'first completion dispatched a premature ready event');

shared.endSessionDraftMutation('session-1');
assert(!('sessionMutationPending' in chatArea.dataset), 'final completion left a stale mutation count');
assert(completionEvents === 1, 'final completion did not dispatch exactly one ready event');
''';
