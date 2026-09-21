import 'package:test/test.dart';

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

  test('the palette answers a direct open request with the unfiltered catalogue', () async {
    final source = (await controllerAsset('dc_conversation_command_controller.js')).readAsStringSync();
    expect(source, contains("document.addEventListener('dartclaw:slash-palette', this.handleSlashPaletteRequest)"));
    expect(source, contains("document.removeEventListener('dartclaw:slash-palette', this.handleSlashPaletteRequest)"));
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
controller.element = { querySelector: (selector) => (selector === '#message-input' ? textarea : null) };

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
''';
