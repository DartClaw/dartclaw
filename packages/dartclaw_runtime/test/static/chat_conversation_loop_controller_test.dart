import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('composer controls render authoritative draft queue steer stop and reconnect states', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_conversationLoopHarness, [controller.absolute.uri.toString()]);
  });
}

const _conversationLoopHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.document = { body: { classList: { add() {}, remove() {} } }, getElementById: () => null };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const beginSessionDraftMutation = () => {};
const endSessionDraftMutation = () => {};
const escapeHtml = (value) => String(value);
const isAtBottom = () => false;
const readHtmxErrorMessage = () => '';
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showBanner = () => {};
const showToast = () => {};
const syncSidebarSessionTitle = () => {};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

function classes() { return { add() {}, remove() {} }; }
const textarea = {
  value: 'Keep this draft', selectionStart: 15, scrollHeight: 40, style: {}, disabled: false,
  addEventListener() {}, removeEventListener() {}, focus() {}, setSelectionRange() {},
};
const send = { disabled: false, hidden: false, textContent: '', title: '', classList: classes(), setAttribute(name, value) { this[name] = value; } };
const stop = { disabled: false, hidden: true };
const steer = { disabled: false, hidden: true };
const queue = { hidden: true, innerHTML: '' };
const saveStatus = { textContent: '' };
const liveStatus = { textContent: '' };
const recovery = { textContent: '', hidden: true };
const recoveryActions = { hidden: true };
const conflictAction = { hidden: true };
const attachmentsInput = { value: '' };
const referencesInput = { value: '' };
const contextTray = { hidden: true, innerHTML: '' };
const submissionId = { value: '' };
const revisionId = { value: '' };
const form = { classList: classes(), dispatchEvent() { this.submitted = true; } };
const nodes = new Map([
  ['#message-input', textarea], ['#send-btn', send], ['#chat-form', form],
  ['[data-dc-chat-target="stopButton"]', stop], ['[data-dc-chat-target="steerButton"]', steer],
  ['[data-dc-chat-target="queue"]', queue], ['[data-dc-chat-target="saveStatus"]', saveStatus],
  ['[data-dc-chat-target="liveStatus"]', liveStatus], ['[data-dc-chat-target="recovery"]', recovery],
  ['[data-dc-chat-target="recoveryActions"]', recoveryActions],
  ['[data-dc-chat-target="conflictAction"]', conflictAction],
  ['[data-dc-chat-target="attachmentsInput"]', attachmentsInput],
  ['[data-dc-chat-target="referencesInput"]', referencesInput],
  ['[data-dc-chat-target="contextTray"]', contextTray],
  ['[data-dc-chat-target="submissionIdInput"]', submissionId],
  ['[data-dc-chat-target="revisionIdInput"]', revisionId],
]);
const element = { dataset: { sessionId: 'session-1' }, querySelector: (selector) => nodes.get(selector) || null };
const controller = new module.default();
Object.assign(controller, {
  element, attachments: [], references: [], streaming: false, canCancel: false,
  conversationReady: true, chatRequestPending: false, draftRevisionId: 'revision-1',
  draftSubmissionId: 'submission-1', draftTouched: true, conversationRevision: 7,
});
controller.saveDraftNow = () => Promise.resolve();

controller.updateSendState();
assert(send.textContent === 'Send' && !send.disabled, 'ready idle draft was not sendable');
controller.streaming = true;
controller.canCancel = true;
controller.updateSendState();
assert(send.textContent === 'Queue', 'running-turn default action did not say Queue');
assert(!textarea.disabled, 'streaming disabled ordinary drafting');
assert(!stop.hidden && !steer.hidden && !stop.disabled && !steer.disabled, 'truthful running controls were absent');
controller.ordinaryControls = false;
controller.updateSendState();
assert(send.textContent === 'Send', 'nonordinary activity advertised ordinary queue admission');
assert(!stop.hidden && steer.hidden, 'nonordinary activity advertised steer or hid existing stop');
controller.ordinaryControls = true;

controller.renderQueue([{ queueId: 'q1', workState: 'held', message: 'Ship after checks', attachments: [{ filename: 'proof.txt' }] }]);
assert(!queue.hidden, 'held queue stayed hidden');
assert(queue.innerHTML.includes('Ship after checks') && queue.innerHTML.includes('proof.txt'), 'queued payload was incomplete');
assert(queue.innerHTML.includes('Send next queued message'), 'oldest held release action was absent');

controller.showDraftSaveFailure();
assert(saveStatus.textContent.includes('will not recover after reload'), 'save failure implied reload recovery');
assert(!recovery.hidden && !recoveryActions.hidden, 'draft recovery actions stayed hidden');

controller.submittedDraft = controller.currentDraft();
controller.submittedRevisionId = 'revision-1';
controller.draftRevisionId = 'newer-revision';
textarea.value = 'Newer unsent edit';
controller.acknowledgeSubmittedDraft();
assert(textarea.value === 'Newer unsent edit', 'acknowledgement cleared a newer revision');

let prevented = false;
form.submitted = false;
controller.handleTextareaKeydown({ isComposing: true, ctrlKey: true, key: 'Enter', preventDefault() { prevented = true; } });
assert(!prevented && !form.submitted, 'IME composition submitted the draft');
controller.handleTextareaKeydown({ isComposing: false, ctrlKey: true, key: 'Enter', preventDefault() { prevented = true; } });
assert(prevented && form.submitted, 'Ctrl+Enter did not submit');
prevented = false;
form.submitted = false;
controller.handleTextareaKeydown({ isComposing: false, metaKey: true, key: 'Enter', preventDefault() { prevented = true; } });
assert(prevented && form.submitted, 'Cmd+Enter did not submit');

let refreshes = 0;
controller.refreshConversationState = () => { refreshes += 1; return Promise.resolve(); };
controller.handleConversationChanged({ detail: { session_id: 'other', revision: 9 } });
controller.handleConversationChanged({ detail: { session_id: 'session-1', revision: 6 } });
controller.handleConversationChanged({ detail: { session_id: 'session-1', revision: 8 } });
controller.handleConversationChanged({ detail: { session_id: 'session-1', revision: 6, turn_id: 'external-turn' } });
assert(refreshes === 2, 'invalidation did not reconcile newer ordinary and retained external turn activity');
''';
