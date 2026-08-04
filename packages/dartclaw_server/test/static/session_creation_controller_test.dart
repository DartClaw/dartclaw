import 'dart:io';

import 'package:test/test.dart';

void main() {
  final controller = File('packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js').existsSync()
      ? File('packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js')
      : File('lib/src/static/controllers/dc_shell_controller.js');

  test('session creation is single-flight and permits retry after failure', () async {
    ProcessResult result;
    try {
      result = await Process.run('node', [
        '--input-type=module',
        '--eval',
        _sessionCreationHarness,
        controller.absolute.uri.toString(),
      ]);
    } on ProcessException catch (error) {
      fail('Node.js is required for controller tests: $error');
    }

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });
}

const _sessionCreationHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function makeButton() {
  const attributes = new Set();
  return {
    disabled: false,
    setAttribute(name) { attributes.add(name); },
    removeAttribute(name) { attributes.delete(name); },
    hasAttribute(name) { return attributes.has(name); },
  };
}

const createButtons = [makeButton(), makeButton()];
let chatArea = null;
const documentListeners = new Map();
globalThis.Stimulus = { Controller: class {} };
globalThis.window = { location: { href: '/sessions/current', pathname: '/sessions/current' }, addEventListener() {} };
globalThis.document = {
  body: { dataset: {}, addEventListener() {}, removeEventListener() {} },
  addEventListener(type, listener) {
    const listeners = documentListeners.get(type) || new Set();
    listeners.add(listener);
    documentListeners.set(type, listeners);
  },
  removeEventListener(type, listener) { documentListeners.get(type)?.delete(listener); },
  dispatchEvent(event) {
    for (const listener of documentListeners.get(event.type) || []) listener(event);
  },
  getElementById: () => null,
  querySelector(selector) {
    if (selector === '.chat-area') return chatArea;
    if (selector === '.chat-area[data-new-chat-draft="true"]') {
      return chatArea?.dataset.newChatDraft === 'true' ? chatArea : null;
    }
    return null;
  },
  querySelectorAll: (selector) => (selector === '[data-session-create]' ? createButtons : []),
};
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };

globalThis.lastToast = null;
let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const apiQs = () => '';
const applyIdenticons = () => {};
const closeAllCustomSelects = () => {};
const confirmDialog = async () => true;
const getApiToken = () => null;
const initCustomSelects = () => {};
const isAtBottom = () => false;
const queueToast = () => {};
const readHtmxErrorMessage = () => '';
const reconcileRestartBanner = () => {};
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showToast = (kind, message) => { globalThis.lastToast = { kind, message }; };
const syncRestartBannerAfterSwap = () => {};
const TOAST_QUEUE_KEY = 'toast-queue';
const dismissRestartBannerState = () => {};
`);

const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();

let fetchCount = 0;
const fetchUrls = [];
let resolveFetch;
globalThis.fetch = (url) => {
  fetchCount += 1;
  fetchUrls.push(url);
  return new Promise((resolve) => { resolveFetch = resolve; });
};

const first = controller.createSession();
const second = controller.createSession();
assert(first === second, 'concurrent activation did not reuse the in-flight request');
await Promise.resolve();
assert(fetchCount === 1, 'concurrent activation issued ' + fetchCount + ' POST requests');
for (const button of createButtons) {
  assert(button.disabled, 'a New Chat entry point stayed enabled while creation was pending');
  assert(button.hasAttribute('aria-busy'), 'a New Chat entry point did not expose its busy state');
}

resolveFetch({ ok: false });
await first;
assert(globalThis.lastToast?.kind === 'error', 'creation failure did not surface an error');
for (const button of createButtons) {
  assert(!button.disabled, 'creation failure left a New Chat entry point disabled');
  assert(!button.hasAttribute('aria-busy'), 'creation failure left stale busy state');
}

const retry = controller.createSession();
await Promise.resolve();
assert(fetchCount === 2, 'creation failure did not permit a retry');
resolveFetch({ ok: true, json: async () => ({ id: 'created' }) });
await retry;
assert(window.location.href === '/sessions/created', 'successful retry did not navigate to the new chat');
assert(fetchUrls.every((url) => url === '/api/sessions/open'), 'New Chat bypassed the draft-reuse endpoint');

let focusCount = 0;
chatArea = {
  dataset: { sessionId: 'created', newChatDraft: 'true' },
  querySelector(selector) {
    if (selector === '#messages .msg') return null;
    if (selector === '#message-input') return { focus() { focusCount += 1; } };
    return null;
  },
};
window.location.href = '/sessions/created';
window.location.pathname = '/sessions/created';
globalThis.fetch = () => {
  fetchCount += 1;
  return Promise.resolve({ ok: true, json: async () => ({ id: 'unexpected' }) });
};
const beforeDraftActivation = fetchCount;
await controller.createSession();
assert(fetchCount === beforeDraftActivation, 'current blank user chat issued another create request');
assert(focusCount === 1, 'current blank user chat did not return focus to the composer');

chatArea.dataset.sessionMutationPending = '1';
delete chatArea.dataset.newChatDraft;
let resolveMutationFetch;
globalThis.fetch = (url) => {
  fetchCount += 1;
  fetchUrls.push(url);
  return new Promise((resolve) => { resolveMutationFetch = resolve; });
};
const beforeMutationActivation = fetchCount;
const afterMutation = controller.createSession();
await Promise.resolve();
assert(fetchCount === beforeMutationActivation, 'New Chat raced a pending title/message mutation');
delete chatArea.dataset.sessionMutationPending;
document.dispatchEvent({ type: 'dartclaw:session-draft-mutation-complete' });
await Promise.resolve();
assert(fetchCount === beforeMutationActivation + 1, 'New Chat did not resume after the pending mutation');
resolveMutationFetch({ ok: true, json: async () => ({ id: 'fresh-after-mutation' }) });
await afterMutation;
assert(window.location.href === '/sessions/fresh-after-mutation', 'pending mutation did not eventually open a fresh chat');

chatArea.dataset.sessionId = 'created';
delete chatArea.dataset.newChatDraft;
window.location.href = '/sessions/created?stale=1';
window.location.pathname = '/sessions/created';
globalThis.fetch = () => Promise.resolve({ ok: true, json: async () => ({ id: 'created' }) });
await controller.createSession();
assert(
  window.location.href === '/sessions/created',
  'same-id reuse without a valid draft marker did not reconcile through navigation',
);
''';
