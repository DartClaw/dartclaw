import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('composer opens and selects references but opens nothing for slash text', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_composerPaletteHarness, [controller.absolute.uri.toString()]);
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
const sendButton = { disabled: false, classList: { add() {}, remove() {} }, setAttribute() {} };
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
