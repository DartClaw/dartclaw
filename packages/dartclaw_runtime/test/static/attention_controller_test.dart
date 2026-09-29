import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('attention mutations carry the exact durable identity of the item acted on', () async {
    final controller = await controllerAsset('dc_shell_controller.js');
    await expectNodeHarness(_attentionHarness, [controller.absolute.uri.toString()]);
  });
}

/// The attention feed settles approvals against a live turn, so every mutation
/// has to name the exact record it saw — a marker or verdict sent without the
/// full identity would settle whatever occupies that slot now.
const _attentionHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.document = {
  documentElement: { style: { setProperty() {} }, dataset: {} },
  body: { addEventListener() {}, removeEventListener() {} },
  addEventListener() {},
  removeEventListener() {},
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
};

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const apiQs = () => '';
const applyIdenticons = () => {};
const beginSessionDraftMutation = () => {};
const closeAllCustomSelects = () => {};
const conversationDraftSessionIds = async () => [];
const confirmDialog = async () => true;
const dismissRestartBannerState = () => {};
const endSessionDraftMutation = () => {};
const getApiToken = () => null;
const initCustomSelects = () => {};
const isAtBottom = () => false;
const queueToast = () => {};
const readHtmxErrorMessage = () => '';
const reconcileRestartBanner = () => {};
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showToast = (kind, message) => { globalThis.lastToast = { kind, message }; };
const syncSidebarSessionTitle = () => {};
const syncRestartBannerAfterSwap = () => {};
const TOAST_QUEUE_KEY = 'toast-queue';
`);

const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
controller.attentionItems = [];

const requests = [];
let nextOk = true;
globalThis.fetch = (url, init) => {
  requests.push({ url, body: JSON.parse(init.body) });
  return Promise.resolve({ ok: nextOk, json: async () => ({}) });
};
controller.refreshAttentionUi = async () => {};

const item = {
  event_id: 'record:req-1',
  session_id: 'sess-1',
  attempt_id: 'attempt-1',
  turn_id: 'turn-1',
  request_id: 'req-1',
  conversation_revision: 7,
  title: 'Approve write',
  detail: 'writes /etc/hosts',
  unread: true,
  action_available: true,
  dismissible: true,
};

await controller.updateAttentionMarker('/api/attention/read', item);
assert(requests.length === 1, 'marking an item read issued no request');
assert(requests[0].url === '/api/attention/read', 'the read marker went to the wrong endpoint');
for (const key of ['event_id', 'session_id', 'conversation_revision']) {
  assert(requests[0].body[key] === item[key], 'the read marker dropped ' + key);
}

await controller.resolveAttention(item, true);
const verdict = requests[1];
assert(verdict.url === '/api/attention/action', 'the verdict went to the wrong endpoint');
for (const key of ['event_id', 'session_id', 'attempt_id', 'turn_id', 'request_id', 'conversation_revision']) {
  assert(verdict.body[key] === item[key], 'the verdict dropped ' + key);
}
assert(verdict.body.approved === true, 'the verdict did not carry the approval decision');

await controller.resolveAttention(item, false);
assert(requests[2].body.approved === false, 'a rejection was sent as an approval');

// A verdict the server no longer recognises must say so rather than leaving the
// row looking settled.
nextOk = false;
globalThis.lastToast = null;
await controller.resolveAttention(item, true);
assert(globalThis.lastToast?.kind === 'error', 'a refused verdict was not reported');

// Only the newest unread item per conversation is marked read; a panel open on
// six items from one conversation must not fire six markers.
requests.length = 0;
nextOk = true;
controller.attentionItems = [
  { ...item, event_id: 'record:new', unread: true },
  { ...item, event_id: 'record:old', unread: true },
  { ...item, session_id: 'sess-2', event_id: 'record:other', unread: true },
  { ...item, session_id: 'sess-3', event_id: 'record:read', unread: false },
];
await controller.markVisibleAttentionRead();
assert(requests.length === 2, 'read marking fired ' + requests.length + ' requests for two conversations');
assert(requests.some((r) => r.body.event_id === 'record:new'), 'the newest unread item was not marked read');
assert(!requests.some((r) => r.body.event_id === 'record:old'), 'a superseded unread item was marked separately');
assert(!requests.some((r) => r.body.event_id === 'record:read'), 'an already-read item was marked again');
''';
