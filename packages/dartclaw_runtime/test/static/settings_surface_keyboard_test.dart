import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('channel mode and guard tabs move focus without submitting and activate on Enter', () async {
    await expectNodeHarness(_harness, [
      (await controllerAsset('dc_channel_detail_controller.js')).absolute.uri.toString(),
      (await controllerAsset('dc_settings_controller.js')).absolute.uri.toString(),
    ]);
  });
}

const _harness = r'''
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.window = globalThis;
globalThis.document = {
  querySelector: () => null,
  querySelectorAll: () => [],
  getElementById: () => null,
  addEventListener() {},
  removeEventListener() {},
  createElement: () => ({ style: {}, classList: { add() {}, remove() {}, toggle() {} }, appendChild() {}, remove() {} }),
  body: { appendChild() {}, removeChild() {} },
};

function host() {
  const listeners = new Map();
  return {
    addEventListener(name, listener) {
      const current = listeners.get(name) || [];
      current.push(listener);
      listeners.set(name, current);
    },
    removeEventListener() {},
    dispatch(name, event) { (listeners.get(name) || []).forEach((listener) => listener(event)); },
  };
}

const channelModule = await import(process.argv[1]);
const channel = new channelModule.default();
channel.element = host();
channel.connect();

let modeGroup;
function modeCard() {
  return {
    focused: false,
    clicks: 0,
    closest(selector) {
      if (selector === '.channel-mode-card') return this;
      if (selector === '[role="radiogroup"]') return modeGroup;
      return null;
    },
    focus() { this.focused = true; },
    click() { this.clicks += 1; },
  };
}
const modes = [modeCard(), modeCard(), modeCard(), modeCard()];
modeGroup = { querySelectorAll: (selector) => selector === '.channel-mode-card' ? modes : [] };
channel.element.dispatch('keydown', { key: 'ArrowRight', target: modes[0], preventDefault() {} });
assert(modes[1].focused, 'ArrowRight did not move mode-card focus');
assert(modes.every((card) => card.clicks === 0), 'moving mode-card focus submitted a mode');
channel.element.dispatch('keydown', { key: 'Enter', target: modes[1], preventDefault() {} });
assert(modes[1].clicks === 1, 'Enter did not activate the focused mode card');

const settingsModule = await import(process.argv[2]);
const settings = new settingsModule.default();
settings.element = host();
settings.connect();

let guardStrip;
function guardTab() {
  return {
    focused: false,
    clicks: 0,
    closest(selector) {
      if (selector === '[data-guard-editor-tab]' || selector === '.tab') return this;
      if (selector === '[role="tablist"]') return guardStrip;
      return null;
    },
    focus() { this.focused = true; },
    click() { this.clicks += 1; },
  };
}
const guards = [guardTab(), guardTab(), guardTab()];
guardStrip = { querySelectorAll: (selector) => selector === '[data-guard-editor-tab]' ? guards : [] };
settings.element.dispatch('keydown', { key: 'ArrowRight', target: guards[0], preventDefault() {} });
assert(guards[1].focused, 'ArrowRight did not move guard-tab focus');
assert(guards.every((tab) => tab.clicks === 0), 'moving guard-tab focus submitted a tab');
settings.element.dispatch('keydown', { key: 'Enter', target: guards[1], preventDefault() {} });
assert(guards[1].clicks === 1, 'Enter did not activate the focused guard tab');

const requests = [];
globalThis.fetch = (url, options) => {
  requests.push({ url, body: JSON.parse(options.body) });
  return Promise.resolve({
    ok: true,
    json: () => Promise.resolve({ verdict: 'pass' }),
  });
};
const result = {
  textContent: '',
  classList: { add() {}, remove() {} },
};
let controls = {
  field: { value: 'extra_rules' },
  value: { value: '/workspace/**' },
  level: { value: 'read_only' },
};
let candidate = {
  querySelector(selector) {
    const match = selector.match(/name="([^"]+)"/);
    return match ? controls[match[1]] : null;
  },
};
let editor = {
  dataset: { activeGuard: 'file' },
  querySelector(selector) {
    if (selector === '[data-guard-editor-add]') return candidate;
    if (selector === '[data-guard-editor-result]') return result;
    return null;
  },
};
const testInput = { value: '/workspace/report.txt' };
const testMode = { value: 'write' };
const testerForm = {
  closest: (selector) => selector === '[data-guard-editor]' ? editor : null,
  querySelector(selector) {
    if (selector === '[data-guard-editor-test-input]') return testInput;
    if (selector === '[data-guard-editor-test-mode]') return testMode;
    return null;
  },
};
const submitTarget = {
  closest: (selector) => selector === '[data-guard-editor-test]' ? testerForm : null,
};

settings.element.dispatch('submit', { target: submitTarget, preventDefault() {} });
await new Promise((resolve) => setTimeout(resolve, 0));
assert(requests.length === 1, 'file tester did not issue one request');
assert(requests[0].url === '/api/config/guards/test', 'file tester used the wrong endpoint');
assert(requests[0].body.guard === 'file', 'file tester lost the active family');
assert(requests[0].body.input.input === '/workspace/report.txt', 'file tester lost the input');
assert(requests[0].body.input.mode === 'write', 'file tester lost the mode');
assert(requests[0].body.candidate.field === 'extra_rules', 'file tester lost the candidate field');
assert(requests[0].body.candidate.value.pattern === '/workspace/**', 'file tester lost the candidate pattern');
assert(requests[0].body.candidate.value.level === 'read_only', 'file tester lost the candidate level');

controls = {
  field: { value: 'extra_allowed_domains' },
  value: { value: 'api.example.com' },
  level: { value: 'no_access' },
};
candidate = {
  querySelector(selector) {
    const match = selector.match(/name="([^"]+)"/);
    return match ? controls[match[1]] : null;
  },
};
editor = {
  dataset: { activeGuard: 'network' },
  querySelector(selector) {
    if (selector === '[data-guard-editor-add]') return candidate;
    if (selector === '[data-guard-editor-result]') return result;
    return null;
  },
};
testInput.value = 'https://api.example.com/v1';
settings.element.dispatch('submit', { target: submitTarget, preventDefault() {} });
await new Promise((resolve) => setTimeout(resolve, 0));
assert(requests.length === 2, 'network tester did not issue its own request');
assert(requests[1].body.guard === 'network', 'replaced editor kept the old family');
assert(requests[1].body.input === 'https://api.example.com/v1', 'network tester did not use scalar input');
assert(requests[1].body.candidate.field === 'extra_allowed_domains', 'network tester lost the candidate field');
assert(requests[1].body.candidate.value === 'api.example.com', 'network tester did not use a scalar candidate');
assert(requests[1].body.candidate.value.pattern === undefined, 'network tester retained file candidate state');
''';
