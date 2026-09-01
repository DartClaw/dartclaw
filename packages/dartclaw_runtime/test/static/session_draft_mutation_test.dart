import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final shared = controllerAsset('shared.js');

  test('overlapping draft mutations complete only after the final mutation', () async {
    await expectNodeHarness(_draftMutationHarness, [(await shared).absolute.uri.toString()]);
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
