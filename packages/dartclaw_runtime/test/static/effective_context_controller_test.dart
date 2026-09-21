import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';
import 'controller_test_support.dart';

void main() {
  test('the context popover traps and restores focus through the lifecycle controller', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains('openContextPopover(event)'));
    expect(source, contains('handleContextDialogKeydown(event)'));
    expect(source, contains("event.key !== 'Tab'"));
    expect(source, contains('this.contextPopoverReturnFocus?.focus()'));
    expect(source, contains("event.key === 'Escape'"));
    // Anchored to the chip, not a modal: a modal steals the transcript behind it
    // for a read-and-edit surface the reader is comparing against that transcript.
    final start = source.indexOf('openContextPopover(event) {');
    final open = source.substring(start, source.indexOf('closeContextPopover() {', start));
    expect(open, isNot(contains('showModal')));
  });

  // Two triggers, two popovers, but one payload: an Apply in either one has to
  // state the whole next-turn context, so the handler reads every control on
  // the page rather than only its own form's.
  test('one apply path reads both popovers and posts the current revision', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains('async applyContext(event)'));
    expect(source, contains('conversation_revision: this.conversationRevision'));
    expect(source, contains("attachments: this.attachments.filter((item) => item.state === 'ready')"));
    expect(source, contains("references: this.references.filter((item) => item.state === 'resolved')"));
    expect(source, contains("'/context'"));
    expect(source, contains("result.error?.message || 'Context change was rejected'"));
    final method = source.substring(
      source.indexOf('async applyContext(event)'),
      source.indexOf('reconcileContext(snapshot)'),
    );
    for (final field in const [
      'effective-context-project',
      'effective-context-directory',
      'effective-context-provider',
      'effective-context-model-input',
      'effective-context-effort-input',
    ]) {
      expect(method, contains(field), reason: field);
    }
    // The message the popover shows is its own, so a rejection reaches the
    // reader in the surface they pressed Apply in.
    expect(method, contains("form.querySelector('.pop-validation')"));
    expect(method, isNot(contains('this.textarea.value')));
  });

  // Opening the sibling hides it directly rather than going through the close
  // path: that path returns focus to the trigger it is leaving, and focus is
  // about to move into the popover being opened.
  test('a trigger opens only the popover it names, and hides the sibling without returning focus', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains("trigger?.getAttribute?.('aria-controls')"));
    final open = source.substring(
      source.indexOf('openContextPopoverFrom(triggerId) {'),
      source.indexOf('closeContextPopover() {'),
    );
    expect(open, contains('if (open && open !== popover) {'));
    expect(open, isNot(contains('this.closeContextPopover()')));
    expect(open, isNot(contains('contextPopoverReturnFocus?.focus()')));
    expect(source, contains("this.element.querySelector('[aria-controls=\"' + popover.id + '\"]')"));
  });

  // The `/model` and `/effort` commands may run while the popover is already
  // open; a toggle there would close it and focus a hidden select.
  test('the palette route opens the model popover idempotently', () async {
    final chat = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(chat, contains("'model-context': () => this.openContextPopoverFrom('effective-context-composer-provider')"));
    final command = (await controllerAsset('dc_conversation_command_controller.js')).readAsStringSync();
    final route = command.substring(
      command.indexOf("if (data.action === 'open_context')"),
      command.indexOf("if (data.action === 'show_help')"),
    );
    expect(route, contains("detail: { action: 'model-context' }"));
    expect(route, isNot(contains('.click()')));
  });

  test('authoritative reconciliation updates controls and projections before absorbing revision', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    final method = source.substring(
      source.indexOf('reconcileContext(snapshot)'),
      source.indexOf('updateContinuityWarning() {'),
    );
    expect(method, contains('snapshot.effective_context'));
    for (final field in const [
      'this.setSelectValue(project, view.projectId)',
      'directory.value = view.directory',
      'this.setSelectValue(provider, view.provider)',
    ]) {
      expect(method, contains(field), reason: field);
    }
    // Model and effort are rebuilt from the applied provider's own catalogue,
    // not assigned into whatever options the previous provider left behind.
    expect(method, contains("this.renderContextOptions(\n      'effective-context-model-input',"));
    expect(method, contains("this.renderContextOptions(\n      'effective-context-effort-input',"));
    expect(
      method.indexOf('this.setSelectValue(project, view.projectId)'),
      lessThan(method.indexOf('this.conversationRevision = nextRevision')),
    );
    expect(method, isNot(contains('this.textarea')));
  });

  // A picker that cannot name a YAML- or API-set value silently unsets it the
  // next time anything else is applied.
  test('the model picker keeps a staged value the adapter does not list', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    final method = source.substring(
      source.indexOf('renderContextOptions(id, catalogue, editable, staged) {'),
      source.indexOf('contextFieldValue(id) {'),
    );
    expect(method, contains("new Option('Provider default', '')"));
    expect(method, contains('if (value && !values.includes(value)) select.append(new Option(value, value));'));
    expect(method, contains('select.disabled = !enabled;'));
  });

  // The enhancer's trigger is the control the reader sees, and a programmatic
  // assignment fires no `change`. The stub records what each select held when
  // the sync reached it, so a call placed before the rewrite reports the
  // previous provider's rows and fails.
  test('every programmatic select write is synced after the rewrite', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_contextSyncHarness, [controller.absolute.uri.toString()]);
  });

  test('the Q9 and E11 browser cases run the layout gate on the chat and session-info surfaces', () async {
    final script = File(await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/run.sh'))
        .readAsStringSync();
    final q9 = script.substring(
      script.indexOf('run_q9_effective_context()'),
      script.indexOf('run_e11_effective_context()'),
    );
    final e11 = script.substring(script.indexOf('run_e11_effective_context()'), script.lastIndexOf(r'case "${CASE}"'));
    for (final section in {'Q9': q9, 'E11': e11}.entries) {
      expect(section.value, contains('assert_layout_tiers'), reason: '${section.key} chat surface');
      expect(section.value, contains('assert_layout_canon'), reason: '${section.key} session-info surface');
    }
  });
}

const _contextSyncHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.document = { body: { classList: { add() {}, remove() {} } }, getElementById: () => null };
globalThis.Option = class {
  constructor(text, value) {
    this.textContent = text;
    this.label = text;
    this.value = value;
    this.disabled = false;
    this.dataset = {};
  }
};
globalThis.syncCalls = [];

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const beginSessionDraftMutation = () => {};
const confirmDialog = async () => true;
const conversationDraftSessionIds = async () => [];
const endSessionDraftMutation = () => {};
const escapeHtml = (value) => String(value);
const inputDialog = async () => null;
const isAtBottom = () => false;
const openConversationDraftDb = async () => null;
const readHtmxErrorMessage = () => '';
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showBanner = () => {};
const showToast = () => {};
const syncSidebarSessionTitle = () => {};
// Stands in for the enhancer's re-read, capturing what it would have seen.
const syncCustomSelect = (select) => {
  globalThis.syncCalls.push({
    id: select.id,
    value: select.value,
    labels: select.options.map((option) => option.textContent),
  });
};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

class FakeSelect {
  constructor(id, options) {
    this.id = id;
    this.options = options;
    this.disabled = false;
    this.value = options[0].value;
  }
  replaceChildren(...nodes) { this.options = nodes; }
  append(node) { this.options.push(node); }
  get selectedOptions() {
    const match = this.options.find((option) => option.value === this.value);
    return match ? [match] : [];
  }
}

const providerOption = (value, models, efforts) => {
  const option = new Option(value, value);
  option.dataset = { models, efforts, modelEditable: 'true', effortEditable: 'true' };
  return option;
};

const project = new FakeSelect('effective-context-project',
  [new Option('Alpha', 'p1'), new Option('Beta', 'p2')]);
const provider = new FakeSelect('effective-context-provider', [
  providerOption('claude', 'sonnet,opus', 'low,high'),
  providerOption('codex', 'gpt-5,gpt-5-mini', 'medium,xhigh'),
]);
const model = new FakeSelect('effective-context-model-input',
  [new Option('Provider default', ''), new Option('sonnet', 'sonnet'), new Option('opus', 'opus')]);
const effort = new FakeSelect('effective-context-effort-input',
  [new Option('Provider default', ''), new Option('low', 'low'), new Option('high', 'high')]);
const directory = { value: '/tmp/alpha', title: '' };
const nodes = {
  '#effective-context-project': project,
  '#effective-context-directory': directory,
  '#effective-context-provider': provider,
  '#effective-context-model-input': model,
  '#effective-context-effort-input': effort,
};

const controller = new module.default();
controller.element = { querySelector: (selector) => nodes[selector] ?? null };
controller.appliedProvider = 'claude';
controller.conversationRevision = 3;

const recorded = (id) => globalThis.syncCalls.filter((call) => call.id === id);
const same = (left, right) => left.length === right.length && left.every((entry, i) => entry === right[i]);

// A provider change rewrites both dependent pickers.
provider.value = 'codex';
controller.contextProviderChanged({ currentTarget: provider });
assert(recorded('effective-context-model-input').length === 1, 'the model picker was not synced');
assert(same(recorded('effective-context-model-input')[0].labels, ['Provider default', 'gpt-5', 'gpt-5-mini']),
  'the model sync read the previous provider catalogue: '
    + JSON.stringify(recorded('effective-context-model-input')[0].labels));
assert(same(recorded('effective-context-effort-input')[0].labels, ['Provider default', 'medium', 'xhigh']),
  'the effort sync read the previous provider catalogue: '
    + JSON.stringify(recorded('effective-context-effort-input')[0].labels));

// A reconcile assigns project and provider straight from the server's view.
globalThis.syncCalls = [];
controller.reconcileContext({
  revision: 7,
  next_context: {},
  effective_context: {
    projectId: 'p2',
    directory: '/tmp/beta',
    provider: 'claude',
    modelEditable: true,
    modelValue: 'opus',
    effortEditable: true,
    effortValue: 'high',
  },
});
assert(same(globalThis.syncCalls.map((call) => call.id), [
  'effective-context-project',
  'effective-context-provider',
  'effective-context-model-input',
  'effective-context-effort-input',
]), 'a reconciled select was left unsynced: ' + JSON.stringify(globalThis.syncCalls.map((call) => call.id)));
assert(recorded('effective-context-project')[0].value === 'p2', 'the project sync ran before the assignment');
assert(recorded('effective-context-provider')[0].value === 'claude', 'the provider sync ran before the assignment');
assert(same(recorded('effective-context-model-input')[0].labels, ['Provider default', 'sonnet', 'opus']),
  'the reconciled model sync read the previous provider catalogue: '
    + JSON.stringify(recorded('effective-context-model-input')[0].labels));
assert(recorded('effective-context-model-input')[0].value === 'opus', 'the staged model was not selected');
assert(same(recorded('effective-context-effort-input')[0].labels, ['Provider default', 'low', 'high']),
  'the reconciled effort sync read the previous provider catalogue: '
    + JSON.stringify(recorded('effective-context-effort-input')[0].labels));
assert(controller.conversationRevision === 7, 'the revision was not absorbed');
''';
