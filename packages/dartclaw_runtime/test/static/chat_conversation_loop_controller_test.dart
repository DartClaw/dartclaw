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
globalThis.dialogState = { inputResult: 'Edited queued message', inputOptions: null };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const beginSessionDraftMutation = () => {};
const endSessionDraftMutation = () => {};
const escapeHtml = (value) => String(value);
const confirmDialog = async () => true;
const inputDialog = async (options) => {
  globalThis.dialogState.inputOptions = options;
  return globalThis.dialogState.inputResult;
};
const isAtBottom = () => false;
const readHtmxErrorMessage = () => '';
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showBanner = () => {};
const showToast = () => {};
const syncSidebarSessionTitle = () => {};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

function classes() { return { add() {}, remove() {}, toggle() {} }; }
const textarea = {
  value: 'Keep this draft', selectionStart: 15, scrollHeight: 40, style: {}, disabled: false,
  addEventListener() {}, removeEventListener() {}, focus() {}, setSelectionRange() {},
};
const send = { disabled: false, hidden: false, type: '', title: '', dataset: {}, classList: classes(), setAttribute(name, value) { this[name] = value; } };
const queueButton = { disabled: false, hidden: true };
const steerToggle = { disabled: false, hidden: true, setAttribute() {} };
const steerButton = { disabled: false, hidden: false };
const steerMenu = { hidden: true };
const saveGlyph = { dataset: {}, title: '', hidden: false, classList: classes(), setAttribute() {} };
const queue = { hidden: true, innerHTML: '' };
const saveStatus = { textContent: '', classList: classes() };
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
const emptyHero = { removed: false, remove() { this.removed = true; } };
const nodes = new Map([
  ['#message-input', textarea], ['#send-btn', send], ['#chat-form', form],
  ['[data-dc-chat-target="queueButton"]', queueButton],
  ['[data-dc-chat-target="steerToggle"]', steerToggle],
  ['[data-dc-chat-target="steerButton"]', steerButton],
  ['[data-dc-chat-target="steerMenu"]', steerMenu],
  ['[data-dc-chat-target="saveGlyph"]', saveGlyph],
  ['[data-dc-chat-target="queue"]', queue], ['[data-dc-chat-target="saveStatus"]', saveStatus],
  ['[data-dc-chat-target="liveStatus"]', liveStatus], ['[data-dc-chat-target="recovery"]', recovery],
  ['[data-dc-chat-target="recoveryActions"]', recoveryActions],
  ['[data-dc-chat-target="conflictAction"]', conflictAction],
  ['[data-dc-chat-target="attachmentsInput"]', attachmentsInput],
  ['[data-dc-chat-target="referencesInput"]', referencesInput],
  ['[data-dc-chat-target="contextTray"]', contextTray],
  ['[data-dc-chat-target="submissionIdInput"]', submissionId],
  ['[data-dc-chat-target="revisionIdInput"]', revisionId],
  ['#chat-empty-state', emptyHero],
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
assert(send.dataset.icon === 'arrow-up' && send.type === 'submit' && !send.disabled, 'ready idle draft was not sendable');
assert(queueButton.hidden && steerToggle.hidden, 'idle composer advertised queue admission');
controller.streaming = true;
controller.canCancel = true;
controller.updateSendState();
assert(send.dataset.icon === 'stop' && send.type === 'button' && !send.disabled, 'running turn did not offer stop on the one filled control');
assert(!textarea.disabled, 'streaming disabled ordinary drafting');
assert(!queueButton.hidden && !queueButton.disabled, 'running-turn queue admission was absent');
assert(!steerToggle.hidden && !steerToggle.disabled && !steerButton.disabled, 'truthful steer controls were absent');
controller.canCancel = false;
controller.updateSendState();
assert(send.disabled, 'a non-cancellable turn still offered stop');
assert(steerToggle.disabled && steerButton.disabled, 'steer stayed live without a cancellable turn');
controller.canCancel = true;
controller.ordinaryControls = false;
controller.updateSendState();
assert(queueButton.hidden && steerToggle.hidden, 'nonordinary activity advertised ordinary queue admission');
assert(send.dataset.icon === 'stop', 'nonordinary activity hid the existing stop');
controller.ordinaryControls = true;
controller.streaming = false;
controller.updateSendState();

controller.renderQueue([{ queueId: 'q1', workState: 'held', message: 'Ship after checks', attachments: [{ filename: 'proof.txt' }] }]);
assert(!queue.hidden, 'held queue stayed hidden');
assert(queue.innerHTML.includes('Ship after checks') && queue.innerHTML.includes('proof.txt'), 'queued payload was incomplete');
assert(queue.innerHTML.includes('>Release<'), 'oldest held release action was absent');
assert(queue.innerHTML.includes('aria-label="Send next queued message"'), 'release did not name what it sends');
assert(queue.innerHTML.includes('queue-row--held'), 'held row lost its status edge');

let queueMutation = null;
controller.queueMutation = async (path, options) => { queueMutation = { path, options }; };
const queueItem = { dataset: { queueId: 'q1' } };
await controller.editQueueItem({ currentTarget: { closest: () => queueItem } });
const queueBody = JSON.parse(queueMutation.options.body);
assert(queueMutation.path === '/queue/q1', 'queued edit lost its item identity');
assert(queueBody.message === 'Edited queued message', 'queued edit did not capture the replacement');
assert(queueBody.attachments[0].filename === 'proof.txt', 'queued edit lost its retained attachments');
assert(dialogState.inputOptions.value === 'Ship after checks' && dialogState.inputOptions.confirmLabel === 'Save', 'queue dialog lost its source value or action');

queueMutation = null;
dialogState.inputResult = null;
await controller.editQueueItem({ currentTarget: { closest: () => queueItem } });
assert(queueMutation === null, 'cancelled queued edit mutated the queue');

// The status row is empty at rest: a composer with nothing to report is not a
// status. A save report shows and then clears itself; a failure holds the row
// until it is resolved.
const fades = [];
const realSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = (fn, ms) => { if (ms === 2000) { fades.push(fn); return 0; } return realSetTimeout(fn, ms); };

controller.setSaveStatus('Saved on this device', { transient: true });
assert(saveStatus.textContent === 'Saved on this device', 'a completed save reported nothing');
assert(saveGlyph.hidden === false, 'the touch-tier glyph stayed hidden while reporting');
assert(fades.length === 1, 'a save report did not schedule its own clear');
fades.pop()();
assert(saveStatus.textContent === '', 'a save report persisted past its fade');
assert(saveGlyph.hidden === true, 'the glyph outlived the report it carried');

controller.showDraftSaveFailure();
assert(saveStatus.textContent.includes('will not recover after reload'), 'save failure implied reload recovery');
assert(fades.length === 0, 'a failure was scheduled to disappear');
assert(saveGlyph.hidden === false, 'the failure glyph was hidden');
assert(!recovery.hidden && !recoveryActions.hidden, 'draft recovery actions stayed hidden');

// A later save report replaces the failure rather than stacking with it.
controller.setSaveStatus('Saving…', { transient: true });
assert(saveStatus.textContent === 'Saving…', 'a new report did not replace the failure');
fades.pop()();
assert(saveStatus.textContent === '', 'the row did not return to rest');
globalThis.setTimeout = realSetTimeout;

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

let authoritativeCanCancel = false;
let authoritativeRevision = 20;
globalThis.fetch = async () => ({
  ok: true,
  status: 200,
  json: async () => ({
    revision: authoritativeRevision,
    submissions: [{ workState: 'running', turnId: 'turn-authoritative' }],
    queue: [],
    activity: {
      ordinary_controls: true,
      turn: { turn_id: 'turn-authoritative', state: authoritativeCanCancel ? 'waiting' : 'running', can_cancel: authoritativeCanCancel },
    },
  }),
});
controller.reconcileContext = () => {};
controller.handleVisibleReadBoundary = () => {};
controller.conversationRevision = 0;
await controller.refreshConversationState();
assert(controller.streaming && send.dataset.icon === 'stop' && send.disabled, 'running claim overrode authoritative non-cancellable state');
authoritativeCanCancel = true;
authoritativeRevision += 1;
await controller.refreshConversationState();
assert(!send.disabled && !steerToggle.disabled, 'authoritative cancellable state did not enable controls');

let refreshes = 0;
controller.refreshConversationState = () => { refreshes += 1; return Promise.resolve(); };
controller.conversationRevision = 7;
controller.chatRequestPending = true;
controller.submittedDraft = controller.currentDraft();
controller.submittedRevisionId = controller.draftRevisionId;
controller.handleFinallyRequest({ detail: { ctx: {
  sourceElement: { id: 'chat-form' }, status: 'swapped', response: { status: 200 },
} } });
assert(emptyHero.removed, 'successful admission retained the empty conversation state');
refreshes = 0;
controller.handleConversationChanged({ detail: { session_id: 'other', revision: 9 } });
controller.handleConversationChanged({ detail: { session_id: 'session-1', revision: 6 } });
controller.handleConversationChanged({ detail: { session_id: 'session-1', revision: 8 } });
controller.handleConversationChanged({ detail: { session_id: 'session-1', revision: 6, turn_id: 'external-turn' } });
assert(refreshes === 2, 'invalidation did not reconcile newer ordinary and retained external turn activity');
''';
