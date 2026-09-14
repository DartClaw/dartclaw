import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('history controller preserves anchors and exact action identity', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_historyHarness, [controller.absolute.uri.toString()]);
  });
}

const _historyHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.requestAnimationFrame = (callback) => callback();
globalThis.NodeFilter = { SHOW_TEXT: 4 };
globalThis.sessionStorage = { setItem() {}, getItem() { return null; }, removeItem() {} };
globalThis.window = { getSelection: () => null, confirm: () => true, prompt: () => 'Edited prompt' };
globalThis.location = { href: 'http://localhost/sessions/session-1', assign() {} };
globalThis.document = {
  body: { classList: { add() {}, remove() {} } },
  activeElement: null,
  getElementById: () => null,
};
Object.defineProperty(globalThis, 'navigator', {
  configurable: true,
  value: { clipboard: { writeText: async () => {} } },
});
globalThis.htmx = { ajax: async () => {}, swap: async () => {} };

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

const tool = { dataset: { toolId: 'tool-1' }, open: true };
const summary = { focused: false, focus() { this.focused = true; } };
tool.querySelector = (selector) => selector === 'summary' ? summary : null;
const message1 = {
  dataset: { messageId: 'message-1' },
  getBoundingClientRect: () => ({ top: 70, bottom: 90 }),
};
const message2 = {
  dataset: { messageId: 'message-2' },
  getBoundingClientRect: () => ({ top: 120, bottom: 170 }),
  querySelectorAll(selector) { return selector === '[data-tool-id]' ? [tool] : []; },
};
const messages = {
  scrollTop: 20,
  getBoundingClientRect: () => ({ top: 100 }),
  querySelectorAll(selector) {
    if (selector === '[data-message-id]') return [message1, message2];
    if (selector === 'details[open][data-tool-id]') return tool.open ? [tool] : [];
    return [];
  },
};
const activity = { hidden: true };
const element = {
  dataset: { sessionId: 'session-1' },
  querySelector(selector) {
    if (selector === '#messages') return messages;
    if (selector === '[data-jump-latest]') return activity;
    return null;
  },
  querySelectorAll(selector) {
    if (selector === 'details[open][data-tool-id]' || selector === 'details[data-tool-id]') return [tool];
    if (selector === '[data-message-id]') return [message1, message2];
    return [];
  },
};
const controller = new module.default();
Object.assign(controller, { element, historyViewState: null });
controller.captureHistoryFocus = () => ({ messageId: 'message-2', toolId: 'tool-1' });
controller.captureHistorySelection = () => ({ messageId: 'message-2', start: 2, end: 5 });
let selectionRestored = null;
controller.restoreHistorySelection = (saved) => { selectionRestored = saved; };

controller.captureHistoryViewState();
assert(controller.historyViewState.anchorId === 'message-2', 'stable visible anchor was not captured');
assert(controller.historyViewState.anchorOffset === 20, 'anchor offset was not captured');
assert(controller.historyViewState.disclosures[0] === 'tool-1', 'open disclosure was not captured');
tool.open = false;
controller.restoreHistoryViewState();
assert(tool.open, 'tool disclosure was not restored');
assert(messages.scrollTop === 20, 'restoring an unchanged anchor moved the viewport');
assert(summary.focused, 'the exact disclosure focus was not restored');
assert(selectionRestored?.start === 2 && selectionRestored?.end === 5, 'selection offsets were not restored');

await controller.processSseMessage(null, { event: 'noop' }, false);
assert(activity.hidden === false, 'new activity did not surface away from the bottom');

let request = null;
globalThis.fetch = async (url, options) => {
  request = { url, options };
  return { ok: true, json: async () => ({ state: 'approved' }) };
};
let refreshed = 0;
controller.refreshHistoryMessages = async () => { refreshed += 1; };
controller.announce = () => {};
controller.showRecovery = () => {};
controller.refreshConversationState = () => {};
const identity = { dataset: { approvalAttemptId: 'attempt-1', approvalTurnId: 'turn-1' } };
const card = {
  dataset: { approvalRequestId: 'request-1' },
  querySelector: () => identity,
  querySelectorAll: () => [{ disabled: false }, { disabled: false }],
};
const approve = { dataset: { approvalDecision: 'approve' }, closest: () => card };
await controller.resolveHistoryApproval(approve);
const approvalBody = JSON.parse(request.options.body);
assert(request.url.endsWith('/approvals/request-1'), 'approval request identity was not addressed');
assert(approvalBody.attempt_id === 'attempt-1' && approvalBody.turn_id === 'turn-1', 'approval owner identity was lost');
assert(approvalBody.decision === 'approve' && refreshed === 1, 'approval did not reconcile authoritative history');

const historyMessage = { dataset: { messageId: 'message-1' }, querySelector: () => ({ textContent: 'Original' }) };
const retry = {
  dataset: { historyAction: 'retry', sourceAttemptId: 'attempt-1' },
  closest: () => historyMessage,
};
controller.generateClientId = () => 'mutation-1';
await controller.runHistoryAction(retry);
const retryBody = JSON.parse(request.options.body);
assert(request.url.endsWith('/attempts/attempt-1/retry'), 'retry source identity was not addressed');
assert(retryBody.mutation_id === 'mutation-1', 'retry idempotency identity was not sent');
assert(refreshed === 2, 'retry did not reconcile authoritative history');
''';
