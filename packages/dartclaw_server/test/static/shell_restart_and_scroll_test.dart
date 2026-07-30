import 'dart:io';

import 'package:test/test.dart';

/// Two shared seams that several surfaces depend on and that are easy to break
/// silently.
///
/// **Restart banner.** The slot holds one stable node; visibility and dismissal
/// live in `shared.js` so the shell controller, the settings save path and an
/// out-of-band slot replacement cannot disagree. The state machine is proven
/// end to end — dormant, pending, updated, dismissed, replaced-while-dismissed,
/// cleared, pending again — including through the *real* Settings listener and
/// its production `PATCH /api/config` → `GET /api/config` refresh, because a
/// direct `checkRestartBanner` call would skip exactly the wiring that breaks.
///
/// **Sticky scroll.** Auto-scroll must consume an intent captured *before* the
/// mutation. Computing it afterwards is the reported runtime failure: appended
/// content has already moved the bottom, so a reader who scrolled up is yanked
/// back down on every streamed frame.
void main() {
  File resolve(String name) {
    final packageRelative = File('packages/dartclaw_server/lib/src/static/controllers/$name');
    return packageRelative.existsSync() ? packageRelative : File('lib/src/static/controllers/$name');
  }

  Future<void> runHarness(String harness, List<String> scripts) async {
    ProcessResult result;
    try {
      result = await Process.run('node', [
        '--input-type=module',
        '--eval',
        harness,
        ...scripts.map((s) => resolve(s).absolute.uri.toString()),
      ]);
    } on ProcessException {
      markTestSkipped('Node is unavailable');
      return;
    }
    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  }

  test('restart banner state survives dismissal, replacement and clearing', () async {
    await runHarness(_restartStateHarness, ['shared.js']);
  });

  test('a real settings save reveals the banner through the production refresh', () async {
    await runHarness(_settingsSaveHarness, ['dc_settings_controller.js']);
  });

  test('auto-scroll honours pre-mutation intent at the threshold boundary', () async {
    await runHarness(_scrollIntentHarness, ['shared.js']);
  });
}

/// Shared DOM shim: enough of an element tree for the banner seam and the
/// settings save path, with selector strings matching production exactly so a
/// change on either side fails here rather than passing vacuously.
const _domShim = r'''
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

class Attrs {
  constructor() { this.map = new Map(); }
  toggleAttribute(name, force) {
    const on = force === undefined ? !this.map.has(name) : force;
    if (on) this.map.set(name, ''); else this.map.delete(name);
    return on;
  }
  hasAttribute(name) { return this.map.has(name); }
  getAttribute(name) { return this.map.has(name) ? this.map.get(name) : null; }
  setAttribute(name, value) { this.map.set(name, String(value)); }
  removeAttribute(name) { this.map.delete(name); }
}

function el(id) {
  const node = new Attrs();
  node.id = id;
  node.textContent = '';
  node.innerHTML = '';
  node.className = '';
  node.style = {};
  node.dataset = {};
  node.children = [];
  node.firstElementChild = null;
  node.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
  node.querySelector = () => null;
  node.querySelectorAll = () => [];
  node.addEventListener = () => {};
  node.appendChild = () => {};
  node.removeChild = () => {};
  node.remove = () => {};
  node.closest = () => null;
  node.focus = () => {};
  return node;
}

// The banner starts exactly as the server renders it dormant.
const banner = el('restart-banner');
banner.toggleAttribute('hidden', true);
banner.toggleAttribute('inert', true);
const fields = el('restart-banner-fields');
const byId = { 'restart-banner': banner, 'restart-banner-fields': fields };

globalThis.Stimulus = { Controller: class {} };
globalThis.document = {
  getElementById: (id) => byId[id] ?? null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener() {},
  removeEventListener() {},
  createElement: () => el(''),
  body: {
    appendChild() {},
    removeChild() {},
    addEventListener() {},
    dataset: {},
    // Toasts are incidental here; they must not crash the save path.
    querySelector: () => el('toast-container'),
  },
};
globalThis.window = globalThis;
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };

const visible = () => !banner.hasAttribute('hidden') && !banner.hasAttribute('inert');
const dormant = () => banner.hasAttribute('hidden') && banner.hasAttribute('inert');
''';

const _restartStateHarness =
    '''
$_domShim

const { reconcileRestartBanner, dismissRestartBanner, syncRestartBannerAfterSwap } =
  await import(process.argv[1]);

// Dormant: the node exists but is hidden, inert and field-empty.
assert(dormant(), 'the server-rendered dormant banner must start hidden and inert');
assert(fields.textContent === '', 'a dormant banner must carry no field text');

// Pending.
reconcileRestartBanner(['agent.model']);
assert(visible(), 'a pending restart must reveal the banner');
assert(fields.textContent === 'agent.model', 'the pending field must be named');

// Updated: a second restart-mutable field joins the same slot.
reconcileRestartBanner(['agent.model', 'port']);
assert(visible(), 'an updated pending set must stay visible');
assert(fields.textContent === 'agent.model, port', 'the revised field list must replace the old one');

// Dismissed.
dismissRestartBanner();
assert(dormant(), 'dismissal must hide and inert the node');
assert(fields.textContent === 'agent.model, port', 'dismissal must not discard the pending state');

// An OOB slot replacement is server-rendered and knows nothing about this
// session's dismissal, so the shared state has to re-assert it.
banner.removeAttribute('hidden');
banner.removeAttribute('inert');
syncRestartBannerAfterSwap();
assert(dormant(), 'navigation must not resurrect a dismissed banner');

// A pending reconcile while dismissed also stays dismissed.
reconcileRestartBanner(['agent.model', 'port']);
assert(dormant(), 'a repeated pending report must not undo dismissal');

// Cleared: the startup sentinel consumed the marker.
reconcileRestartBanner([]);
assert(dormant(), 'a cleared banner must be hidden and inert');
assert(fields.textContent === '', 'clearing must blank the field list');

// ...and clearing resets dismissal, so the next independent restart surfaces.
reconcileRestartBanner(['server.port']);
assert(visible(), 'a later independent pending set must be able to surface again');
assert(fields.textContent === 'server.port', 'the new field must be named');
''';

const _settingsSaveHarness =
    '''
$_domShim

// One .content-area carrying one dirty .settings-form, plus the listener capture
// that lets the test dispatch the same submit a real operator would.
const listeners = {};
const input = { tagName: 'INPUT', type: 'text', value: '3000', disabled: false, hidden: false };
const group = {
  dataset: { field: 'server.port' },
  closest: () => null,
  querySelector: (sel) => (sel === 'input, select, textarea' ? input : null),
};
const form = {
  dataset: {},
  closest: () => null,
  classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
  querySelectorAll: (sel) => (sel === '[data-field]' ? [group] : []),
  querySelector: () => ({ disabled: false, textContent: 'Save', classList: { add() {}, remove() {} } }),
};
const content = {
  dataset: {},
  addEventListener: (type, fn) => { listeners[type] = fn; },
  querySelector: () => null,
  querySelectorAll: () => [],
};
// initSettingsForm() gates on finding a .settings-form, and location.hash
// drives the initial tab.
document.querySelector = (sel) => {
  if (sel === '.content-area') return content;
  if (sel === '.settings-form') return form;
  return null;
};
document.querySelectorAll = (sel) => (sel === '.settings-form' ? [form] : []);
globalThis.location = { hash: '' };

let patched = null;
let getCount = 0;
let pendingFields = [];
globalThis.fetch = async (url, options) => {
  if (options?.method === 'PATCH') {
    patched = JSON.parse(options.body);
    return { ok: true, json: async () => ({ data: { applied: [], pendingRestart: pendingFields } }) };
  }
  getCount += 1;
  return {
    ok: true,
    json: async () => ({
      server: { port: Number(input.value) },
      _meta: { restartPending: pendingFields.length > 0, pendingFields },
    }),
  };
};

const settings = await import(process.argv[1]);
const controller = new settings.default();
controller.element = { addEventListener() {} };
controller.connect();

// Let the initial GET /api/config settle: it sets the baseline and attaches the
// listeners the save path runs through.
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
for (let i = 0; i < 10; i += 1) await settle();
assert(getCount >= 1, 'connect() must load the config baseline');
assert(dormant(), 'no restart.pending means the banner starts dormant');
assert(typeof listeners.submit === 'function', 'the settings save listener must be attached');

// The operator edits a restart-mutable field and saves.
input.value = '8080';
pendingFields = ['server.port'];
listeners.submit({ target: { closest: (sel) => (sel === '.settings-form' ? form : null) }, preventDefault() {} });
for (let i = 0; i < 10; i += 1) await settle();

assert(patched !== null, 'the save must issue a real PATCH /api/config');
assert(getCount >= 2, 'the production path must re-GET the config after saving');
assert(visible(), 'the PATCH -> GET refresh must reveal the restart banner');
assert(fields.textContent === 'server.port', 'the banner must name the field that needs a restart');

// A second restart-mutable field through the same real path.
input.value = '9090';
pendingFields = ['server.port', 'server.host'];
listeners.submit({ target: { closest: (sel) => (sel === '.settings-form' ? form : null) }, preventDefault() {} });
for (let i = 0; i < 10; i += 1) await settle();
assert(fields.textContent === 'server.port, server.host', 'the refreshed field list must replace the old one');

// The startup sentinel consumes the marker: _meta.restartPending goes false.
input.value = '7070';
pendingFields = [];
listeners.submit({ target: { closest: (sel) => (sel === '.settings-form' ? form : null) }, preventDefault() {} });
for (let i = 0; i < 10; i += 1) await settle();
assert(dormant(), 'a cleared restart marker must return the banner to dormant');
assert(fields.textContent === '', 'clearing must blank the field list');
''';

const _scrollIntentHarness =
    '''
$_domShim

const { isAtBottom, scrollToBottom } = await import(process.argv[1]);

// Threshold boundary: 32px is still "at bottom", 33px is not.
const at = (distance) => ({ scrollHeight: 1000, clientHeight: 400, scrollTop: 600 - distance });
assert(isAtBottom(at(0)) === true, 'a container scrolled to the end is at bottom');
assert(isAtBottom(at(32)) === true, 'exactly 32px from the end is within the threshold');
assert(isAtBottom(at(33)) === false, '33px from the end is outside the threshold');

// A container that does not overflow has nothing to scroll back through.
assert(isAtBottom({ scrollHeight: 300, clientHeight: 300, scrollTop: 0 }) === true,
  'a non-overflowing container must report at-bottom so new content keeps tracking');
assert(isAtBottom(null) === false, 'a missing container must not claim to be at bottom');

// The consume contract: only force or a captured intent may move the scroller.
function root(scrollTop) {
  const messages = { scrollHeight: 1000, clientHeight: 400, scrollTop };
  return { messages, querySelector: (sel) => (sel === '.messages' ? messages : null) };
}

const readingBack = root(100);
scrollToBottom(readingBack, {});
assert(readingBack.messages.scrollTop === 100, 'a bare call must not re-anchor');
scrollToBottom(readingBack, { stickToBottom: false });
assert(readingBack.messages.scrollTop === 100, 'a reader who scrolled up must stay put');

const following = root(590);
scrollToBottom(following, { stickToBottom: isAtBottom(following.messages) });
assert(following.messages.scrollTop === 1000, 'a reader at the bottom must keep following');

// Intent captured BEFORE the mutation, consumed after. Recomputing afterwards
// is the actual bug: growth pushes the bottom away and the reader looks
// "scrolled up" even though they were following.
const streaming = root(590);
const intent = isAtBottom(streaming.messages);
streaming.messages.scrollHeight = 4000;
assert(isAtBottom(streaming.messages) === false, 'growth alone must change the post-mutation reading');
scrollToBottom(streaming, { stickToBottom: intent });
assert(streaming.messages.scrollTop === 4000, 'the pre-mutation intent must survive the content growth');

// The same growth must NOT drag a reader who had genuinely scrolled up.
const scrolledUp = root(100);
const noIntent = isAtBottom(scrolledUp.messages);
scrolledUp.messages.scrollHeight = 4000;
scrollToBottom(scrolledUp, { stickToBottom: noIntent });
assert(scrolledUp.messages.scrollTop === 100, 'a streamed frame must not interrupt reading back');

// Initial render and history restoration still anchor unconditionally.
const cold = root(0);
scrollToBottom(cold, { force: true });
assert(cold.messages.scrollTop === 1000, 'force must anchor regardless of intent');
''';
