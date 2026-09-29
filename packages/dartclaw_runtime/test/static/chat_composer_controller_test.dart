import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';
import 'controller_test_support.dart';

void main() {
  test('composer opens and selects references but opens nothing for slash text', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_composerPaletteHarness, [controller.absolute.uri.toString()]);
  });

  // The commands button used to prepend `/` to whatever the composer already
  // held, so the palette filtered on the draft, matched no command, and showed
  // only its passthrough row — the "clicking it does nothing" report.
  test('the commands button seeds a slash only into an empty composer', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_commandsButtonHarness, [controller.absolute.uri.toString()]);
  });

  // Two highlighted rows leave the reader unsure which one Enter or Tab picks.
  test('pointer movement moves the palette cursor in the @ reference palette', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_referencePointerHarness, [controller.absolute.uri.toString()]);
    // The option styles only the cursor; a :hover fill of its own would paint a
    // second row under a resting pointer.
    final css = File(await resolveServerPackagePath('lib', 'src', 'static', 'app.css')).readAsStringSync();
    expect(css, isNot(contains('.composer-palette-option:hover')));
  });

  // A press on the header or a row would otherwise move focus to
  // `#main-content` and take the arrow keys away from the composer.
  test('palette press keeps input focus in the composer for the @ reference palette', () async {
    final template = File(await resolveServerPackagePath('lib', 'src', 'templates', 'chat.html')).readAsStringSync();
    final palette = RegExp(r'<div class="composer-reference-palette[\s\S]*? hidden>').firstMatch(template)!.group(0)!;
    expect(palette, contains('data-action="mousedown->dc-chat#keepComposerFocus"'));
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_referencePressHarness, [controller.absolute.uri.toString()]);
  });

  test('the palette answers a direct open request with the unfiltered catalogue', () async {
    final source = (await controllerAsset('dc_conversation_command_controller.js')).readAsStringSync();
    expect(source, contains("document.addEventListener('dartclaw:slash-palette', this.handleSlashPaletteRequest)"));
    expect(source, contains("document.removeEventListener('dartclaw:slash-palette', this.handleSlashPaletteRequest)"));
    expect(source, contains("document.addEventListener('dartclaw:slash-palette-close', this.handleSlashPaletteClose)"));
    expect(
      source,
      contains("document.removeEventListener('dartclaw:slash-palette-close', this.handleSlashPaletteClose)"),
    );
    final method = source.substring(
      source.indexOf('handleSlashPaletteRequest() {'),
      source.indexOf('async renderSlash(query)'),
    );
    expect(method, contains("this.renderSlash('')"));
    // An unfiltered render means no query reaches renderCatalog, so nothing can
    // narrow the catalogue to the passthrough row.
    expect(method, isNot(contains('textarea')));
  });
}

const _composerPaletteHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.document = { body: { classList: { add() {}, remove() {} } }, getElementById: () => null };

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

const textarea = {
  value: '/',
  selectionStart: 1,
  scrollHeight: 40,
  style: {},
  focus() {},
  setSelectionRange(start) { this.selectionStart = start; },
};
const sendButton = { disabled: false, dataset: {}, classList: { add() {}, remove() {} }, setAttribute() {} };
const list = {
  innerHTML: '',
  querySelectorAll() { return []; },
};
const palette = {
  hidden: true,
  querySelector(selector) { return selector === '.composer-palette-list' ? list : null; },
};
const attachmentsInput = { value: '' };
const referencesInput = { value: '' };
const contextTray = { hidden: true, innerHTML: '' };
const element = {
  dataset: { sessionId: 'session-1' },
  querySelector(selector) {
    if (selector === '#message-input') return textarea;
    if (selector === '#send-btn') return sendButton;
    if (selector === '[data-dc-chat-target="referencePalette"]') return palette;
    if (selector === '[data-dc-chat-target="attachmentsInput"]') return attachmentsInput;
    if (selector === '[data-dc-chat-target="referencesInput"]') return referencesInput;
    if (selector === '[data-dc-chat-target="contextTray"]') return contextTray;
    return null;
  },
};
const controller = new module.default();
controller.element = element;
controller.attachments = [];
controller.references = [];
controller.filteredReferences = [];
controller.activeReferenceIndex = 0;
controller.streaming = false;

let fetchCount = 0;
globalThis.fetch = async (url) => {
  fetchCount += 1;
  assert(url === '/api/sessions/session-1/references?q=project', 'unexpected reference URL: ' + url);
  return { ok: true, json: async () => ({ references: [{ type: 'project', id: 'p1', label: 'Project One' }] }) };
};

controller.handleTextareaInput();
assert(palette.hidden, 'slash text opened a composer overlay');
assert(fetchCount === 0, 'slash text requested reference suggestions');

textarea.value = '@project';
textarea.selectionStart = textarea.value.length;
controller.handleTextareaInput();
await new Promise((resolve) => setTimeout(resolve, 0));
assert(fetchCount === 1, 'reference text did not request suggestions');
assert(!palette.hidden, 'reference palette did not open');
assert(list.innerHTML.includes('@Project One'), 'reference option was not rendered');

let prevented = false;
controller.handlePaletteKey({ key: 'ArrowDown', preventDefault() { prevented = true; } });
assert(prevented, 'reference navigation did not consume ArrowDown');
prevented = false;
controller.handlePaletteKey({ key: 'Escape', preventDefault() { prevented = true; } });
assert(prevented, 'reference dismissal did not consume Escape');
assert(palette.hidden, 'reference palette stayed open after Escape');

controller.handleTextareaInput();
await new Promise((resolve) => setTimeout(resolve, 0));
assert(fetchCount === 2, 'reference palette did not reopen');
prevented = false;
controller.handlePaletteKey({ key: 'Enter', preventDefault() { prevented = true; } });
assert(prevented, 'reference selection did not consume Enter');
assert(controller.references.length === 1, 'reference selection was not recorded');
assert(controller.references[0].id === 'p1', 'wrong reference was selected');
assert(palette.hidden, 'reference palette stayed open after selection');
''';

const _commandsButtonHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const dispatched = [];
globalThis.Stimulus = { Controller: class {} };
globalThis.document = {
  body: { classList: { add() {}, remove() {} } },
  getElementById: () => null,
  dispatchEvent(event) { dispatched.push(event.type); return true; },
};

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const escapeHtml = (value) => String(value);
const showToast = () => {};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

const textarea = {
  value: '',
  selectionStart: 0,
  inputEvents: 0,
  focus() {},
  setSelectionRange(start) { this.selectionStart = start; },
  dispatchEvent(event) { if (event.type === 'input') this.inputEvents += 1; return true; },
};
const controller = new module.default();
let paletteOpen = false;
controller.element = {
  querySelector(selector) {
    if (selector === '#message-input') return textarea;
    if (selector === '[data-slash-palette]:not([hidden])') return paletteOpen ? {} : null;
    return null;
  },
};

controller.openCommands();
assert(textarea.value === '/', 'empty composer was not seeded with a slash: ' + textarea.value);
assert(textarea.selectionStart === 1, 'caret was not placed after the slash');
assert(textarea.inputEvents === 1, 'the seeded slash did not drive the palette through an input event');
assert(dispatched.length === 0, 'an empty composer took the direct-open path');

textarea.value = 'let me think about';
textarea.inputEvents = 0;
controller.openCommands();
assert(textarea.value === 'let me think about', 'the draft was mangled into a query: ' + textarea.value);
assert(textarea.inputEvents === 0, 'the draft was pushed through the typing path');
assert(dispatched.length === 1 && dispatched[0] === 'dartclaw:slash-palette',
  'the palette was not asked to open directly: ' + JSON.stringify(dispatched));

textarea.value = '/mod';
controller.openCommands();
assert(textarea.value === '/mod', 'slash text already typed was re-prefixed: ' + textarea.value);
assert(dispatched.length === 1, 'slash text took the direct-open path instead of filtering');

// The button toggles: a second press closes the palette and takes back the
// slash the first press seeded, through the typing path so the draft sees it.
paletteOpen = true;
textarea.value = '/';
textarea.inputEvents = 0;
dispatched.length = 0;
controller.openCommands();
assert(dispatched.length === 1 && dispatched[0] === 'dartclaw:slash-palette-close',
  'a second press did not ask the palette to close: ' + JSON.stringify(dispatched));
assert(textarea.value === '', 'the seeded slash stayed behind: ' + textarea.value);
assert(textarea.inputEvents === 1, 'the cleared slash did not reach the draft through an input event');

// Slash text the user typed survives the close.
textarea.value = '/mod';
textarea.inputEvents = 0;
dispatched.length = 0;
controller.openCommands();
assert(dispatched.length === 1 && dispatched[0] === 'dartclaw:slash-palette-close',
  'a second press over typed slash text did not close the palette');
assert(textarea.value === '/mod', 'closing the palette discarded typed text: ' + textarea.value);
assert(textarea.inputEvents === 0, 'closing over typed text re-ran the typing path');
''';

/// Loads dc-chat with the shared module stubbed out.
const _chatControllerModule = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.document = { body: { classList: { add() {}, remove() {} } }, getElementById: () => null };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const escapeHtml = (value) => String(value);
const showToast = () => {};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

// A reference list whose rows are real enough to hold listeners and
// attributes: rendering parses them back out of the markup it was given.
function referenceList() {
  let rows = [];
  return {
    get rows() { return rows; },
    set innerHTML(html) {
      rows = [...html.matchAll(/<button([^>]*)>/g)]
        .map(([, attributes]) => ({
          dataset: { referenceIndex: attributes.match(/data-reference-index="(\d+)"/)[1] },
          attributes: attributes.includes('aria-selected="true"') ? { 'aria-selected': 'true' } : {},
          listeners: {},
          addEventListener(name, listener) { this.listeners[name] = listener; },
          setAttribute(name, value) { this.attributes[name] = value; },
        }));
    },
    querySelectorAll() { return rows; },
  };
}

function referenceController(references) {
  const list = referenceList();
  const palette = { hidden: true, querySelector: (selector) => (selector === '.composer-palette-list' ? list : null) };
  const controller = new module.default();
  controller.element = {
    querySelector: (selector) => (selector === '[data-dc-chat-target="referencePalette"]' ? palette : null),
  };
  controller.filteredReferences = references;
  controller.activeReferenceIndex = 0;
  controller.renderReferencePalette();
  return { controller, list, palette };
}

const references = [
  { type: 'project', id: 'p1', label: 'Alpha' },
  { type: 'project', id: 'p2', label: 'Beta' },
  { type: 'project', id: 'p3', label: 'Gamma' },
];
''';

const _referencePointerHarness =
    _chatControllerModule +
    r'''
const { controller, list } = referenceController(references);
const selected = () => list.rows.filter((row) => row.attributes['aria-selected'] === 'true')
  .map((row) => row.dataset.referenceIndex);
assert(selected().join() === '0', 'the first row did not start as the cursor: ' + selected().join());

list.rows[1].listeners.pointermove();
assert(controller.activeReferenceIndex === 1, 'pointer movement did not move the cursor');
assert(selected().join() === '1', 'more or other than the pointer row is highlighted: ' + selected().join());

// The keyboard continues from where the pointer left the cursor, and Enter
// picks the row the cursor is on.
let picked = null;
controller.selectReference = (index) => { picked = index; };
controller.handlePaletteKey({ key: 'ArrowDown', preventDefault() {} });
assert(controller.activeReferenceIndex === 2, 'ArrowDown did not continue from the pointer row');
controller.handlePaletteKey({ key: 'Enter', preventDefault() {} });
assert(picked === 2, 'Enter did not pick the cursor row: ' + picked);
''';

const _referencePressHarness =
    _chatControllerModule +
    r'''
const { controller, list } = referenceController(references);
let prevented = false;
controller.keepComposerFocus({ preventDefault() { prevented = true; } });
assert(prevented, 'a press in the reference palette left the composer');

// The press is held, the click is not: a row is still chosen.
let picked = null;
controller.selectReference = (index) => { picked = index; };
list.rows[2].listeners.click();
assert(picked === 2, 'a row click no longer picks the reference: ' + picked);
''';
