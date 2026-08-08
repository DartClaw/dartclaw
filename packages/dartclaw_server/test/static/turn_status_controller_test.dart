import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_tasks_controller.js');
  final chatController = controllerAsset('dc_chat_controller.js');

  test('inactive turn mount activates and returns to inert state', () async {
    await expectNodeHarness(_turnStatusHarness, [
      controller.absolute.uri.toString(),
      chatController.absolute.uri.toString(),
    ]);
  });
}

const _turnStatusHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function extractFunction(source, name) {
  const start = source.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('missing function ' + name);
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') depth -= 1;
    if (depth === 0) return source.slice(start, index + 1);
  }
  throw new Error('unterminated function ' + name);
}

function extractMethod(source, name) {
  const start = source.indexOf('  ' + name + '(');
  if (start < 0) throw new Error('missing method ' + name);
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') depth -= 1;
    if (depth === 0) return source.slice(start + 2, index + 1);
  }
  throw new Error('unterminated method ' + name);
}

const stateElement = { textContent: '' };
const reasonClasses = new Set(['value-absent']);
const reasonElement = {
  textContent: '',
  classList: {
    toggle(name, enabled) {
      if (enabled) reasonClasses.add(name);
      else reasonClasses.delete(name);
    },
  },
};
const timeElements = new Map([
  ['[data-turn-status-waiting]', { textContent: '' }],
  ['[data-turn-status-stuck]', { textContent: '' }],
  ['[data-turn-status-timeout]', { textContent: '' }],
]);
const buttonAttributes = new Map();
const button = {
  hidden: true,
  disabled: true,
  setAttribute(name, value) { buttonAttributes.set(name, value); },
  removeAttribute(name) { buttonAttributes.delete(name); },
};
const panelAttributes = new Map([['data-turn-status-session-id', 'session-1']]);
const panel = {
  hidden: true,
  getAttribute(name) { return panelAttributes.get(name) ?? null; },
  setAttribute(name, value) { panelAttributes.set(name, value); },
  removeAttribute(name) { panelAttributes.delete(name); },
  querySelector(selector) {
    if (selector === '[data-turn-status-state]') return stateElement;
    if (selector === '[data-turn-status-reason]') return reasonElement;
    if (selector === '[data-turn-cancel]') return button;
    return timeElements.get(selector) ?? null;
  },
};

const source = await readFile(new URL(process.argv[1]), 'utf8');
const activeStatesMatch = source.match(/const activeTurnStates = new Set\((\[[^\]]+\])\);/);
assert(activeStatesMatch, 'production active-turn state declaration was not found');
const activeTurnStates = new Set(eval(activeStatesMatch[1]));
assert(
  Array.from(activeTurnStates).join(',') === 'running,waiting,stuck,cancelling',
  'production active-turn state membership drifted',
);
const displayedTurnPanel = () => panel;
const setPanelText = eval('(' + extractFunction(source, 'setPanelText') + ')');
const formatElapsedTimeIso = eval('(' + extractFunction(source, 'formatElapsedTimeIso') + ')');
const formatRemainingTimeIso = eval('(' + extractFunction(source, 'formatRemainingTimeIso') + ')');
const applyTurnWaitState = eval('(' + extractFunction(source, 'applyTurnWaitState') + ')');

const now = Date.now();
const waitingSince = new Date(now - 2 * 60 * 1000 - 5000).toISOString();
const timeoutAt = new Date(now + 10 * 60 * 1000 + 5000).toISOString();

applyTurnWaitState({
  type: 'turn_wait_state',
  session_id: 'session-1',
  turn_id: 'turn-1',
  state: 'waiting',
  wait_reason: 'session_lock',
  waiting_since: waitingSince,
  global_timeout_at: timeoutAt,
  can_cancel: true,
});
assert(panel.hidden === false, 'running update did not reveal the inert mount');
assert(panelAttributes.get('data-turn-status-turn-id') === 'turn-1', 'active turn id was not mounted');
assert(stateElement.textContent === 'Waiting', 'active state label was not updated');
assert(reasonElement.textContent === 'session lock', 'wait reason was not normalized');
assert(timeElements.get('[data-turn-status-waiting]').textContent === '2m ago', 'waiting time was not relative');
assert(timeElements.get('[data-turn-status-timeout]').textContent === 'in 10m', 'timeout was not relative');
assert(!timeElements.get('[data-turn-status-waiting]').textContent.includes('T'), 'live status leaked a raw ISO timestamp');
assert(button.hidden === false && button.disabled === false, 'authoritative cancel action did not appear');
assert(buttonAttributes.get('data-turn-id') === 'turn-1', 'cancel action did not receive the active turn id');

applyTurnWaitState({
  type: 'turn_wait_state',
  session_id: 'session-1',
  turn_id: 'turn-1',
  state: 'completed',
  can_cancel: false,
});
assert(panel.hidden === true, 'terminal update left the status panel visible');
assert(!panelAttributes.has('data-turn-status-turn-id'), 'terminal update left a stale turn id');
assert(button.hidden === true && button.disabled === true, 'terminal update left cancel actionable');
assert(!buttonAttributes.has('data-turn-id'), 'terminal update left a stale cancel turn id');

let turnStatusRefreshGeneration = 0;
const taskResponses = [];
globalThis.fetch = () => new Promise((resolve) => taskResponses.push(resolve));
const refreshDisplayedTurnStatus = eval('(' + extractFunction(source, 'refreshDisplayedTurnStatus') + ')');

refreshDisplayedTurnStatus();
refreshDisplayedTurnStatus();
taskResponses[1]({
  ok: true,
  json: async () => ({ session_id: 'session-1', turn_id: 'turn-new', state: 'waiting', can_cancel: true }),
});
await new Promise((resolve) => setTimeout(resolve, 0));
assert(panelAttributes.get('data-turn-status-turn-id') === 'turn-new', 'new task snapshot was not applied');
taskResponses[0]({
  ok: true,
  json: async () => ({ session_id: 'session-1', turn_id: 'turn-old', state: 'completed', can_cancel: false }),
});
await new Promise((resolve) => setTimeout(resolve, 0));
assert(panelAttributes.get('data-turn-status-turn-id') === 'turn-new', 'older task snapshot overwrote newer state');

const chatSource = await readFile(new URL(process.argv[2]), 'utf8');
const chatMethods = eval('({' +
  extractMethod(chatSource, '_startTurnStatusPolling') + ',' +
  extractMethod(chatSource, '_stopTurnStatusPolling') +
'})');
const chatResponses = [];
let scheduledPoll = null;
globalThis.fetch = () => new Promise((resolve) => chatResponses.push(resolve));
globalThis.setInterval = (callback) => { scheduledPoll = callback; return 1; };
globalThis.clearInterval = () => {};
const chat = {
  ...chatMethods,
  streaming: true,
  canCancel: false,
  sessionId: 'chat-1',
  turnStatusTimer: null,
  turnStatusPollGeneration: 0,
  updateSendState() {},
};

chat._startTurnStatusPolling();
scheduledPoll();
chatResponses[1]({ ok: true, json: async () => ({ can_cancel: true }) });
await new Promise((resolve) => setTimeout(resolve, 0));
assert(chat.canCancel === true, 'new chat snapshot was not applied');
chatResponses[0]({ ok: true, json: async () => ({ can_cancel: false }) });
await new Promise((resolve) => setTimeout(resolve, 0));
assert(chat.canCancel === true, 'older chat snapshot overwrote newer state');

chat._startTurnStatusPolling();
chat._stopTurnStatusPolling();
chatResponses[2]({ ok: true, json: async () => ({ can_cancel: true }) });
await new Promise((resolve) => setTimeout(resolve, 0));
assert(chat.canCancel === false, 'retired chat poll generation changed cancel state');
''';
