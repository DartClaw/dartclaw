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
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
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
const results = { replaceChildren() {} };
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
