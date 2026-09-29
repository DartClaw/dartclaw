import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  late String source;

  setUpAll(() async {
    source = (await controllerAsset('dc_conversation_command_controller.js')).readAsStringSync();
  });

  test('keyboard handling preserves browser Find and ignores IME composition', () {
    expect(source, contains('if (event.isComposing) return'));
    expect(source, contains("event.key.toLowerCase() === 'k'"));
    expect(source, isNot(contains("event.key.toLowerCase() === 'f'")));
  });

  test('latest response token, dialog focus trap, and fragment-safe delegation are explicit', () {
    expect(source, contains('const generation = ++this.searchGeneration'));
    expect(source, contains('this.refreshDialog(queryInput.closest(\'dialog\'), generation)'));
    expect(source, contains('if (!dialog?.open || generation !== this.searchGeneration) return'));
    expect(source, contains('generation !== this.searchGeneration'));
    expect(source, contains('data.request_token !== String(generation)'));
    expect(source, contains('trapFocus(event, dialog)'));
    expect(source, contains("document.addEventListener('click', this.handleClick)"));
    expect(source, contains("document.removeEventListener('click', this.handleClick)"));
  });

  test('query navigation preserves draft and reauthorizes the selected target', () {
    expect(source, contains("sessionStorage.setItem('dartclaw-search-return'"));
    expect(source, contains("draft: this.textarea()?.value || ''"));
    expect(source, contains("'/api/conversation-search/target'"));
  });

  test('temporary search navigation puts no draft or return content in browser persistence', () async {
    final controller = await controllerAsset('dc_conversation_command_controller.js');
    await expectNodeHarness(_temporarySearchNavigationHarness, [controller.absolute.uri.toString()]);
  });

  test('conversation updates preserve search while newer queries and close supersede it', () async {
    final controller = await controllerAsset('dc_conversation_command_controller.js');
    await expectNodeHarness(_conversationChangeSearchHarness, [controller.absolute.uri.toString()]);
  });

  // Two highlighted rows leave the reader unsure which one Enter runs, so the
  // pointer drives the keyboard's cursor instead of painting its own.
  test('pointer movement moves the palette cursor in the slash palette and the Cmd+K results', () async {
    final controller = await controllerAsset('dc_conversation_command_controller.js');
    await expectNodeHarness(_pointerCursorHarness, [controller.absolute.uri.toString()]);
    // A scroll moves rows under a resting pointer and fires boundary events, not
    // moves; a boundary listener would hand the cursor back to the pointer.
    for (final boundary in ['pointerover', 'pointerenter', 'mouseover', 'mouseenter']) {
      expect(source, isNot(contains("'$boundary'")), reason: boundary);
    }
  });

  // A press on a palette's header or row would otherwise hand focus to
  // `#main-content`, outline it, and take the arrow keys away from the palette.
  test('palette press keeps input focus while a row click still chooses it', () async {
    final controller = await controllerAsset('dc_conversation_command_controller.js');
    await expectNodeHarness(_palettePressHarness, [controller.absolute.uri.toString()]);
    expect(source, contains("document.addEventListener('mousedown', this.handleMouseDown)"));
    expect(source, contains("document.removeEventListener('mousedown', this.handleMouseDown)"));
    expect(source, contains("document.addEventListener('pointerdown', this.handlePointerDown)"));
    expect(source, contains("document.removeEventListener('pointerdown', this.handlePointerDown)"));
  });

  test('search highlights are built from text nodes rather than result HTML', () {
    expect(source, contains("document.createElement('mark')"));
    expect(source, contains('highlight.textContent = snippet.slice(start, end)'));
    expect(source, contains('document.createTextNode(snippet.slice(end)'));
  });

  test('native skill selection crosses the typed action route before mutating the composer', () {
    expect(source, isNot(contains('dataset.nativeInvocation')));
    expect(source, contains("if (data.action === 'send_provider')"));
    expect(source, contains('textarea.value = data.message'));
    expect(source, contains("this.apiUrl('/api/command-actions')"));
  });
}

const _temporarySearchNavigationHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
let retention = 'process';
const stored = new Map();
globalThis.sessionStorage = {
  getItem(key) { return stored.get(key) ?? null; },
  setItem(key, value) { stored.set(key, value); },
  removeItem(key) { stored.delete(key); },
};
globalThis.history = {
  pushState() { throw new Error('temporary return state reached history'); },
  replaceState() { throw new Error('temporary return state reached history'); },
};
globalThis.location = {
  href: 'http://localhost/sessions/source',
  origin: 'http://localhost',
  pathname: '/sessions/source',
  assign(href) { globalThis.assignedHref = href; },
};
globalThis.document = {
  querySelector(selector) {
    if (selector === '.chat-area') return { dataset: { sessionId: 'source', retention } };
    return null;
  },
};
globalThis.fetch = async () => ({ ok: true });

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace("import { apiQs, showToast } from './shared.js';", "const apiQs = () => ''; const showToast = () => {};");
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
const textarea = {
  value: 'temporary unique draft',
  dispatchEvent() {},
};
controller.textarea = () => textarea;
controller.withToken = (href) => href;
controller.apiUrl = (path) => path;

function option(scope) {
  const dialog = {
    dataset: { commandDialog: scope },
    querySelector: () => ({ value: 'temporary unique query' }),
  };
  return {
    dataset: {
      searchSession: 'target',
      searchMessage: 'message',
      searchHref: '/sessions/target#message-message',
    },
    closest: () => dialog,
    remove() {},
  };
}

for (const scope of ['current', 'global']) {
  stored.set('dartclaw-search-return', 'stale content');
  await controller.openSearchTarget(option(scope));
  assert(!stored.has('dartclaw-search-return'), scope + ' temporary navigation persisted return content');
  assert(globalThis.assignedHref === '/sessions/target#message-message', scope + ' navigation did not proceed');
}

stored.set('dartclaw-search-return', JSON.stringify({
  href: location.href,
  draft: 'stale temporary draft',
}));
await controller.restoreSearchReturn();
assert(!stored.has('dartclaw-search-return'), 'temporary restore retained content');

retention = 'durable';
await controller.openSearchTarget(option('current'));
const durable = JSON.parse(stored.get('dartclaw-search-return'));
assert(durable.draft === 'temporary unique draft', 'durable positive control did not preserve the draft');
assert(durable.query === 'temporary unique query', 'durable positive control did not preserve the query');

let restores = 0;
const returnInput = { value: '' };
const returnDialog = {
  querySelector() { return returnInput; },
  querySelectorAll() { return []; },
};
document.querySelector = selector => {
  if (selector === '.chat-area') return { dataset: { sessionId: 'source', retention } };
  if (selector === '[data-command-dialog="current"]') return returnDialog;
  return null;
};
controller.openDialog = async scope => {
  assert(scope === 'current', 'saved current scope changed');
  restores += 1;
};
location.href = 'http://localhost/sessions/source?message=message#message-message';
await controller.restoreSearchReturn();
assert(stored.has('dartclaw-search-return'), 'same-path search target consumed return state');
assert(restores === 0, 'same-path search target restored before browser return');

location.href = durable.href;
await controller.restoreSearchReturn();
assert(!stored.has('dartclaw-search-return'), 'saved origin retained consumed return state');
assert(restores === 1, 'exact saved origin did not restore search');
assert(textarea.value === 'temporary unique draft', 'saved origin did not restore draft');
assert(returnInput.value === 'temporary unique query', 'saved origin did not restore query');
''';

const _conversationChangeSearchHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

globalThis.Stimulus = { Controller: class {} };
let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace("import { apiQs, showToast } from './shared.js';", "const apiQs = () => ''; const showToast = () => {};");
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
controller.catalogs = new Map([['current|session', {}]]);
controller.searchGeneration = 0;
controller.searchTimer = null;

const status = { textContent: 'Type to search.' };
let clearedResults = 0;
const results = { replaceChildren() { clearedResults += 1; } };
const lifecycle = { value: 'all' };
const project = { value: '', trim() { return ''; } };
const dialog = {
  open: true,
  dataset: { commandDialog: 'global' },
  close() { this.open = false; },
  querySelector(selector) {
    if (selector === '[data-command-query]') return input;
    if (selector === '[data-command-status]') return status;
    if (selector === '[data-command-results]') return results;
    if (selector === '[data-search-lifecycle]') return lifecycle;
    if (selector === '[data-search-project]') return project;
    return null;
  },
};
const input = {
  value: 'debounced',
  closest(selector) {
    if (selector === '[data-command-query]') return this;
    if (selector === 'dialog') return dialog;
    return null;
  },
};

const debounceSearches = [];
controller.search = async (_, query, generation) => debounceSearches.push({ query, generation });
controller.handleInput({ target: input });
const debounceGeneration = controller.searchGeneration;
controller.handleConversationChanged();
assert(controller.searchGeneration === debounceGeneration, 'conversation update invalidated pending debounce');
assert(controller.catalogs.size === 0, 'conversation update retained stale command catalog');
await new Promise(resolve => setTimeout(resolve, 200));
assert(debounceSearches.length === 1 && debounceSearches[0].query === 'debounced', 'debounced search did not run');

controller.search = module.default.prototype.search.bind(controller);
controller.apiUrl = (path, parameters) => path + '?' + parameters.toString();
const pending = new Map();
globalThis.fetch = url => {
  const query = new URL(url, 'http://localhost').searchParams.get('q');
  const request = deferred();
  pending.set(query, request);
  return request.promise;
};
const rendered = [];
controller.renderSearch = (_, rows) => rendered.push(rows[0]?.message_id);

const inflightGeneration = ++controller.searchGeneration;
const inflight = controller.search(dialog, 'inflight', inflightGeneration);
controller.handleConversationChanged();
pending.get('inflight').resolve({
  ok: true,
  json: async () => ({ request_token: String(inflightGeneration), total: 1, results: [{ message_id: 'inflight' }] }),
});
await inflight;
assert(rendered.at(-1) === 'inflight', 'conversation update discarded in-flight search');

const failedGeneration = ++controller.searchGeneration;
const failedSearch = controller.search(dialog, 'failed', failedGeneration);
pending.get('failed').resolve({
  ok: false,
  json: async () => ({ error: { message: 'Conversation search is temporarily unavailable' } }),
});
await failedSearch;
assert(status.textContent === 'Conversation search is temporarily unavailable', 'tokenless search failure stayed pending');
assert(clearedResults === 1, 'live search failure retained stale results');

const networkFailureGeneration = ++controller.searchGeneration;
const networkFailure = controller.search(dialog, 'network-failure', networkFailureGeneration);
pending.get('network-failure').reject(new TypeError('Failed to fetch'));
await networkFailure;
assert(status.textContent === 'Search is unavailable', 'network failure exposed a raw browser error');
assert(clearedResults === 2, 'network failure retained stale results');

const staleFailureGeneration = ++controller.searchGeneration;
const staleFailure = controller.search(dialog, 'stale-failure', staleFailureGeneration);
const recoveredGeneration = ++controller.searchGeneration;
const recoveredSearch = controller.search(dialog, 'recovered', recoveredGeneration);
pending.get('recovered').resolve({
  ok: true,
  json: async () => ({ request_token: String(recoveredGeneration), total: 1, results: [{ message_id: 'recovered' }] }),
});
await recoveredSearch;
pending.get('stale-failure').resolve({
  ok: false,
  json: async () => ({ error: { message: 'Stale search failure' } }),
});
await staleFailure;
assert(rendered.at(-1) === 'recovered', 'stale search failure replaced newer results');
assert(status.textContent === '1 results', 'stale search failure replaced newer status');
assert(clearedResults === 2, 'stale search failure cleared newer results');

const oldGeneration = ++controller.searchGeneration;
const oldSearch = controller.search(dialog, 'old', oldGeneration);
const newGeneration = ++controller.searchGeneration;
const newSearch = controller.search(dialog, 'new', newGeneration);
pending.get('new').resolve({
  ok: true,
  json: async () => ({ request_token: String(newGeneration), total: 1, results: [{ message_id: 'new' }] }),
});
await newSearch;
pending.get('old').resolve({
  ok: true,
  json: async () => ({ request_token: String(oldGeneration), total: 1, results: [{ message_id: 'old' }] }),
});
await oldSearch;
assert(rendered.at(-1) === 'new' && !rendered.includes('old'), 'older query replaced newer search');

dialog.open = true;
const closingGeneration = ++controller.searchGeneration;
const closingSearch = controller.search(dialog, 'closing', closingGeneration);
controller.closeDialog(dialog);
pending.get('closing').resolve({
  ok: true,
  json: async () => ({ request_token: String(closingGeneration), total: 1, results: [{ message_id: 'closing' }] }),
});
await closingSearch;
assert(!rendered.includes('closing'), 'closed dialog accepted an obsolete response');
''';

/// Loads the controller with the shared module stubbed out.
const _commandControllerModule = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace("import { apiQs, showToast } from './shared.js';", "const apiQs = () => ''; const showToast = () => {};");
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
''';

const _pointerCursorHarness =
    _commandControllerModule +
    r'''
function row(label, { disabled = false } = {}) {
  const classes = new Set();
  return {
    label,
    disabled,
    attributes: {},
    scrolls: 0,
    classList: {
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
      contains(name) { return classes.has(name); },
    },
    setAttribute(name, value) { this.attributes[name] = value; },
    scrollIntoView() { this.scrolls += 1; },
    closest(selector) {
      if (selector === '[data-command-option]') return this;
      return selector === 'dialog.command-dialog[open], [data-slash-palette]' ? host : null;
    },
  };
}

let host;
for (const surface of ['slash', 'global']) {
  const status = row('/status');
  const fork = row('/fork');
  const help = row('/help');
  const offline = row('/offline', { disabled: true });
  const rows = [status, fork, offline, help];
  host = {
    querySelectorAll(selector) {
      assert(selector === '[data-command-option]:not([disabled])', 'unexpected row query: ' + selector);
      return rows.filter((candidate) => !candidate.disabled);
    },
    querySelector(selector) {
      assert(selector === '[data-command-option].palette-item--active', 'unexpected active query: ' + selector);
      return rows.find((candidate) => candidate.classList.contains('palette-item--active')) ?? null;
    },
  };
  globalThis.document = {
    querySelector(selector) {
      if (surface === 'global' && selector === 'dialog.command-dialog[open]') return host;
      if (surface === 'slash' && selector === '[data-slash-palette]:not([hidden])') return host;
      return null;
    },
  };
  const controller = new module.default();
  const chosen = [];
  controller.chooseOption = (option) => chosen.push(option.label);
  controller.activeOption = 0;
  controller.markActive(host.querySelectorAll('[data-command-option]:not([disabled])'));
  const highlighted = () => rows.filter((candidate) => candidate.classList.contains('palette-item--active'));
  const selected = () => rows.filter((candidate) => candidate.attributes['aria-selected'] === 'true');

  controller.handlePointerMove({ target: fork });
  assert(highlighted().length === 1 && highlighted()[0] === fork, surface + ': pointer did not move the cursor');
  assert(selected().length === 1 && selected()[0] === fork, surface + ': aria-selected did not follow the cursor');
  assert(status.attributes['aria-selected'] === 'false', surface + ': the keyboard row kept aria-selected');
  assert(fork.scrolls === 0, surface + ': pointer movement scrolled the list under the pointer');

  controller.handlePointerMove({ target: offline });
  assert(highlighted()[0] === fork, surface + ': a disabled row took the cursor');

  controller.handleKeydown({ key: 'Enter', preventDefault() {} });
  assert(chosen.join() === '/fork', surface + ': Enter did not choose the pointer row: ' + chosen.join());

  // The keyboard continues from where the pointer left the cursor.
  controller.handleKeydown({ key: 'ArrowDown', preventDefault() {} });
  assert(highlighted().length === 1 && highlighted()[0] === help, surface + ': ArrowDown did not continue from the pointer row');
}
''';

const _palettePressHarness =
    _commandControllerModule +
    r'''
// `closest` matches when any selector in the list names one of the element's
// ancestors, so each target states where it sits.
function target(...ancestors) {
  return {
    closest(selector) {
      return selector.split(',').some((part) => ancestors.includes(part.trim())) ? this : null;
    },
  };
}

globalThis.document = { querySelector: () => null };
const controller = new module.default();
const pressed = (element) => {
  let prevented = false;
  controller.handleMouseDown({ target: element, preventDefault() { prevented = true; } });
  return prevented;
};

assert(pressed(target('[data-slash-palette]')), 'a press in the slash palette moved focus out of the composer');
assert(pressed(target('dialog.command-dialog [data-command-results]')), 'a press on the Cmd+K results left the query input');
assert(!pressed(target('dialog.command-dialog')), 'a press on the Cmd+K query input itself was blocked');
assert(!pressed(target('#main-content')), 'a press outside every palette was blocked');

// The press is held, the click is not: a row is still chosen.
const chosen = [];
controller.chooseOption = (option) => chosen.push(option);
const option = {
  closest(selector) { return selector === '[data-command-option]' ? this : null; },
};
controller.handleClick({ target: option, preventDefault() {} });
assert(chosen.length === 1 && chosen[0] === option, 'a row click no longer chooses the row');

// A press outside the open slash palette closes it. The palette, the composer
// that drives it and the commands button that toggles it are not outside.
const palette = { hidden: false };
globalThis.document = {
  querySelector: (selector) => (selector === '[data-slash-palette]:not([hidden])' && !palette.hidden ? palette : null),
};
const pressDown = (element) => controller.handlePointerDown({ target: element });
for (const inside of ['[data-slash-palette]', '#message-input', '[data-action~="dc-chat#openCommands"]']) {
  pressDown(target(inside));
  assert(!palette.hidden, 'a press on ' + inside + ' closed the slash palette');
}
pressDown(target('#main-content'));
assert(palette.hidden, 'a press outside the slash palette left it open');
''';
