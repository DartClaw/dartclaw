import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final chat = controllerAsset('dc_chat_controller.js');
  final shell = controllerAsset('dc_shell_controller.js');

  test('turn status retries every 2.5 seconds with one persistent warning until recovery', () async {
    await expectNodeHarness(_harness + _chatRetry, [(await chat).absolute.uri.toString()]);
  });

  test('recovering one status source preserves the warning from the other', () async {
    await expectNodeHarness(_harness + _independentRecovery, [
      (await chat).absolute.uri.toString(),
      (await shell).absolute.uri.toString(),
    ]);
  });

  test('an HTTP status error shows a warning and disables Stop until recovery', () async {
    await expectNodeHarness(_harness + _httpError, [(await chat).absolute.uri.toString()]);
  });

  test('a late success leaves a newer status failure visible', () async {
    await expectNodeHarness(_harness + _lateSuccess, [(await chat).absolute.uri.toString()]);
  });

  test('a late failure cannot undo a newer successful status', () async {
    await expectNodeHarness(_harness + _lateFailure, [(await chat).absolute.uri.toString()]);
  });

  test('disconnecting the chat ignores a pending status failure', () async {
    await expectNodeHarness(_harness + _retiredFailure, [(await chat).absolute.uri.toString()]);
  });

  for (final (action, description) in const [
    ('disconnect', 'disconnecting the chat'),
    ('idle', 'returning the chat to idle'),
  ]) {
    test('$description removes only its status warning', () async {
      await expectNodeHarness(_harness + _retireVisibleWarning, [
        (await chat).absolute.uri.toString(),
        (await shell).absolute.uri.toString(),
        action,
      ]);
    });
  }

  test('reconnecting the same chat ignores status from its former connection', () async {
    await expectNodeHarness(_harness + _reconnect, [(await chat).absolute.uri.toString()]);
  });
}

const _harness = r'''
import assert from 'node:assert/strict';
import { mock } from 'node:test';

class Element extends EventTarget {
  children = [];
  dataset = {};
  parentNode = null;
  innerHTML = '';
  classNames = new Set();
  classList = {
    add: (name) => this.classNames.add(name),
    remove: (name) => this.classNames.delete(name),
    contains: (name) => this.classNames.has(name),
  };

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
  }

  remove() {
    this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
    this.parentNode = null;
  }

  setAttribute() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
}

const body = new Element();
globalThis.window = new EventTarget();
globalThis.document = Object.assign(new EventTarget(), {
  body,
  createElement: () => new Element(),
  getElementById: (id) => body.children.find((el) => el.id === id) ?? null,
  querySelector: () => null,
});
globalThis.Stimulus = { Controller: class {} };

mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });

async function settle() {
  // Let the fetch chain settle, then finish any outgoing toast animations.
  await new Promise(setImmediate);
  for (const toast of [...(document.getElementById('toast-container')?.children ?? [])]) {
    toast.dispatchEvent(new Event('animationend'));
  }
}

async function advance(milliseconds) {
  mock.timers.tick(milliseconds);
  await settle();
}

const chatWarning = 'Turn status updates are unavailable';
const attentionWarning = 'Attention updates are unavailable';
function warnings() {
  const toasts = document.getElementById('toast-container')?.children ?? [];
  return toasts.map((toast) => toast.innerHTML.replace(/<[^>]+>/g, ''));
}

const ok = (body) => ({ ok: true, json: async () => body });
const unavailable = () => ({ ok: false, status: 503 });
const healthyTurn = () => ok({ turn_id: 'turn-1', state: 'running', can_cancel: true });
function unreachable() { throw new TypeError('Server unreachable'); }

let turnStatus = unreachable;
let attentionAvailable = false;
let turnRequests = 0;
function deferTurnStatus() {
  let reply;
  let fail;
  const response = new Promise((resolve, reject) => { reply = resolve; fail = reject; });
  turnStatus = () => response;
  return { reply, fail };
}

globalThis.fetch = async (url) => {
  if (url === '/api/sessions/session-1/turn-status') {
    turnRequests++;
    return turnStatus();
  }
  if (url.startsWith('/api/attention?')) {
    return attentionAvailable ? ok({ items: [] }) : unavailable();
  }
  if (url === '/api/sessions/session-1/attachments/limits') return ok({ max_attachment_bytes: 1024 });
  if (url === '/api/sessions/session-1/conversation-state') return ok({ revision: 1 });
  throw new Error('Unexpected fetch ' + url);
};

const { default: ChatController } = await import(process.argv[1]);
const stopButton = new Element();
const chat = new ChatController();
chat.element = new Element();
chat.element.dataset = { sessionId: 'session-1', retention: 'process' };
chat.element.querySelector = (selector) => selector === '#send-btn' ? stopButton : null;
chat.connect();

async function startStreaming() {
  await settle();
  chat.disableInput();
  await settle();
}
''';

const _chatRetry = r'''
await startStreaming();
assert.deepEqual(warnings(), [chatWarning], 'the first failed status request should show a warning');
assert.equal(stopButton.disabled, true, 'stop should wait for confirmed status');
assert.equal(turnRequests, 1, 'the first status request should run immediately');

await advance(2499);
assert.equal(turnRequests, 1, 'the poll retried before 2.5 seconds');
await advance(1);
assert.equal(turnRequests, 2, 'the poll did not retry at 2.5 seconds');
assert.deepEqual(warnings(), [chatWarning], 'a repeated failure should leave exactly one warning');

await advance(2000);
assert.deepEqual(warnings(), [chatWarning], 'the warning should outlast regular toasts');
turnStatus = healthyTurn;
await advance(500);
assert.deepEqual(warnings(), [], 'a recovered poll should dismiss its warning');
assert.equal(stopButton.disabled, false, 'recovered status should make the active turn stoppable');

turnStatus = unreachable;
await advance(2500);
assert.deepEqual(warnings(), [chatWarning], 'losing transport after recovery should show the warning again');
assert.equal(stopButton.disabled, false, 'losing transport should preserve the last known Stop state');
chat.disconnect();
''';

const _independentRecovery = r'''
await startStreaming();
const { default: ShellController } = await import(process.argv[2]);
const shell = new ShellController();
await shell.refreshAttentionUi();
assert.deepEqual(warnings().sort(), [attentionWarning, chatWarning], 'both failing sources should show warnings');

attentionAvailable = true;
await shell.refreshAttentionUi();
await settle();
assert.deepEqual(warnings(), [chatWarning], 'attention recovery should leave the turn warning');

turnStatus = healthyTurn;
await advance(2500);
assert.deepEqual(warnings(), [], 'turn recovery should dismiss the remaining warning');

turnStatus = unreachable;
await advance(2500);
assert.deepEqual(warnings(), [chatWarning], 'a new failure after recovery should warn again');
chat.disconnect();
''';

const _httpError = r'''
turnStatus = healthyTurn;
await startStreaming();
assert.deepEqual(warnings(), []);
assert.equal(stopButton.disabled, false, 'healthy status should enable Stop');

turnStatus = unavailable;
await advance(2500);
assert.deepEqual(warnings(), [chatWarning], 'HTTP 503 should show a status warning');
assert.equal(stopButton.disabled, true, 'HTTP 503 should disable Stop');

turnStatus = healthyTurn;
await advance(2500);
assert.deepEqual(warnings(), [], 'a healthy status should clear the warning');
assert.equal(stopButton.disabled, false, 'a healthy cancellable status should enable Stop again');
chat.disconnect();
''';

const _lateSuccess = r'''
const old = deferTurnStatus();
await startStreaming();
turnStatus = unreachable;
await advance(2500);
assert.equal(turnRequests, 2);
assert.deepEqual(warnings(), [chatWarning], 'the newer failed request should show a warning');

old.reply(healthyTurn());
await settle();
assert.deepEqual(warnings(), [chatWarning], 'the older success should leave the warning visible');
assert.equal(stopButton.disabled, true, 'the older success should leave Stop disabled');
chat.disconnect();
''';

const _lateFailure = r'''
const old = deferTurnStatus();
await startStreaming();
turnStatus = healthyTurn;
await advance(2500);
assert.equal(turnRequests, 2);
assert.equal(stopButton.disabled, false, 'Stop should reflect the latest successful status');

old.fail(new TypeError('Old request lost its connection'));
await settle();
assert.deepEqual(warnings(), [], 'the older failure should leave the warning dismissed');
assert.equal(stopButton.disabled, false, 'the older failure should leave Stop enabled');
chat.disconnect();
''';

const _retiredFailure = r'''
const old = deferTurnStatus();
await startStreaming();
assert.equal(turnRequests, 1);
chat.disconnect();

old.fail(new TypeError('The retired request lost its connection'));
await settle();
assert.deepEqual(warnings(), [], 'disconnecting should retire the pending status request');
''';

const _retireVisibleWarning = r'''
await startStreaming();
const { default: ShellController } = await import(process.argv[2]);
const shell = new ShellController();
await shell.refreshAttentionUi();
assert.deepEqual(warnings().sort(), [attentionWarning, chatWarning], 'both failing sources should show warnings');

const pending = deferTurnStatus();
await advance(2500);
assert.equal(turnRequests, 2);
if (process.argv[3] === 'disconnect') chat.disconnect();
else chat.enableInput();
await settle();
assert.deepEqual(warnings(), [attentionWarning], 'retiring the poll should clear only its warning');

pending.fail(new TypeError('The retired request lost its connection'));
await settle();
assert.deepEqual(warnings(), [attentionWarning], 'a late failure should leave only the attention warning');
''';

const _reconnect = r'''
const old = deferTurnStatus();
await startStreaming();
chat.disconnect();

turnStatus = unreachable;
chat.connect();
await startStreaming();
assert.equal(turnRequests, 2);
assert.deepEqual(warnings(), [chatWarning], 'the active connection should show its failure');

old.reply(healthyTurn());
await settle();
assert.deepEqual(warnings(), [chatWarning], 'the former connection should leave the warning visible');
assert.equal(stopButton.disabled, true, 'the former connection should leave Stop disabled');
chat.disconnect();
''';
