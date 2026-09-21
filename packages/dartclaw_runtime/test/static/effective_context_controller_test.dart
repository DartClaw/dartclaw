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

  // A separate Apply step left the popover showing a selection the next turn
  // would not run. Each commit applies at once, states the whole next-turn
  // context from both popovers, and never races another commit.
  test('context applies on change, one request per commit, serialised', () async {
    final template = File(await resolveServerPackagePath('lib', 'src', 'templates', 'chat.html')).readAsStringSync();
    final popovers = template.substring(
      template.indexOf('id="effective-context-project-pop"'),
      template.indexOf('<dialog id="temporary-create-dialog"'),
    );
    expect(popovers, isNot(contains('type="submit"')));
    expect(popovers, isNot(contains('Apply')));
    // Selects commit on pick and Directory on Enter or leaving the field: both
    // are its `change`, so nothing listens per keystroke.
    expect(popovers, contains('data-action="change->dc-chat#applyContext submit->dc-chat#holdContextSubmit"'));
    expect(popovers, contains('<form id="effective-context-model-form" data-action="change->dc-chat#applyContext">'));
    expect(popovers, contains('data-action="change->dc-chat#contextProviderChanged"'));
    expect(popovers, isNot(contains('input->')));
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_applyOnChangeHarness, [controller.absolute.uri.toString()]);
  });

  test('a rejected apply restores the applied context and keeps the typed directory', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_rejectedApplyHarness, [controller.absolute.uri.toString()]);
  });

  // The notice is about the provider the conversation last ran on; showing it
  // for a pick that has not been applied, or keeping it after the pick is
  // undone, misreports what the next turn will lose.
  test('the continuity notice follows the applied context after a client apply', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_continuityHarness, [controller.absolute.uri.toString()]);
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
      source.indexOf('updateContinuityWarning(view) {'),
    );
    expect(method, contains('snapshot.effective_context'));
    for (final field in const [
      'this.setSelectValue(project, view.projectId)',
      'directory.value = view.directory',
      'this.setSelectValue(provider, view.provider)',
    ]) {
      expect(method, contains(field), reason: field);
    }
    // Model and effort are rendered from the server's option data for the
    // applied provider, not assigned into whatever the previous one left.
    expect(method, contains('this.renderOptions(model, view.modelOptions'));
    expect(method, contains('this.renderOptions(effort, view.effortOptions'));
    expect(
      method.indexOf('this.setSelectValue(project, view.projectId)'),
      lessThan(method.indexOf('this.conversationRevision = nextRevision')),
    );
    expect(method, isNot(contains('this.textarea')));
  });

  // The server builds every option – labels, Default, per-model efforts – so
  // the page cannot drift from it: a provider switch, a model pick and a
  // reconcile all render that data rather than rebuilding a list of their own.
  test('model catalogue options are rendered verbatim and Effort follows the picked model', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_modelCatalogueHarness, [controller.absolute.uri.toString()]);
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

/// Loads dc-chat with the shared module stubbed and the select double the
/// harnesses below build their context controls from.
const _contextControllerModule = r'''
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
globalThis.toasts = [];

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
const showToast = (type, message) => globalThis.toasts.push(message);
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

// Server option data in the shape `effectiveContextView` builds: each model
// carries the Effort picker it selects, as JSON, and whether it is editable.
const modelEntry = (value, label, efforts) => ({
  value,
  label,
  efforts: JSON.stringify([{ value: '', label: 'Default' }, ...efforts.map((effort) => ({ value: effort, label: effort }))]),
  effortEditable: String(efforts.length > 0),
});
const FIVE = ['low', 'medium', 'high', 'xhigh', 'max'];
const catalogues = {
  claude: [
    modelEntry('', 'Default · Opus', FIVE),
    modelEntry('opus', 'Opus', FIVE),
    modelEntry('sonnet', 'Sonnet', FIVE),
    modelEntry('haiku', 'Haiku', []),
  ],
  codex: [
    modelEntry('', 'Default · GPT-5', ['medium', 'xhigh']),
    modelEntry('gpt-5', 'GPT-5', ['medium', 'xhigh']),
    modelEntry('gpt-5-mini', 'GPT-5 mini', ['medium', 'xhigh']),
  ],
};

const providerOption = (value) => {
  const option = new Option(value, value);
  option.dataset = { models: JSON.stringify(catalogues[value]), modelEditable: 'true' };
  return option;
};

// The Effort options the server renders for [modelValue] on [provider].
const effortsFor = (provider, modelValue) =>
  JSON.parse((catalogues[provider].find((entry) => entry.value === modelValue) ?? catalogues[provider][0]).efforts);

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

// A server snapshot of the effective context: claude, project p1, nothing
// chosen, no continuity notice, unless [view] says otherwise. The pickers are
// that provider's server-built option data.
function snapshot(revision, view = {}) {
  const provider = view.provider ?? 'claude';
  return {
    revision,
    next_context: {},
    effective_context: {
      projectId: 'p1',
      directory: '/tmp/alpha',
      provider,
      modelEditable: true,
      effortEditable: true,
      modelValue: '',
      effortValue: '',
      composer: 'claude',
      continuityHidden: true,
      modelOptions: catalogues[provider],
      effortOptions: effortsFor(provider, view.modelValue ?? ''),
      ...view,
    },
  };
}
const accepted = (body) => ({ ok: true, json: async () => body });
const refused = (message) => ({ ok: false, json: async () => ({ error: { message } }) });

// Both popovers' controls behind a controller that has reconciled revision 3.
// Every PATCH is held until the harness answers it, and records what the
// model picker offered when it was sent.
function contextFixture() {
  const project = new FakeSelect('effective-context-project', [new Option('Alpha', 'p1'), new Option('Beta', 'p2')]);
  const provider = new FakeSelect('effective-context-provider', [providerOption('claude'), providerOption('codex')]);
  const model = new FakeSelect('effective-context-model-input', [new Option('Default', '')]);
  const effort = new FakeSelect('effective-context-effort-input', [new Option('Default', '')]);
  const directory = {
    id: 'effective-context-directory',
    value: '',
    title: '',
    attributes: {},
    setAttribute(name, value) { this.attributes[name] = value; },
    removeAttribute(name) { delete this.attributes[name]; },
  };
  const continuity = { hidden: true };
  const pill = { textContent: '' };
  const validations = [{ hidden: true, textContent: '' }, { hidden: true, textContent: '' }];
  // The popover the commits are made in; open unless a case closes it.
  const popover = { hidden: false };
  const nodes = {
    '#effective-context-project': project,
    '#effective-context-directory': directory,
    '#effective-context-provider': provider,
    '#effective-context-model-input': model,
    '#effective-context-effort-input': effort,
    '#effective-context-continuity': continuity,
    '#effective-context-composer-provider': pill,
  };
  const controller = new module.default();
  controller.element = {
    dataset: { sessionId: 'session-1' },
    querySelector: (selector) => nodes[selector] ?? null,
    querySelectorAll: (selector) => {
      if (selector === '.pop-validation') return validations;
      if (selector === '.pop-project, .pop-model') return [popover];
      return [];
    },
  };
  controller.attachments = [];
  controller.references = [];
  controller.reconcileContext(snapshot(3));
  const requests = [];
  globalThis.fetch = (url, init) => {
    const response = deferred();
    requests.push({
      url,
      method: init?.method ?? 'GET',
      body: init?.body ? JSON.parse(init.body) : null,
      modelOptions: model.options.map((option) => option.textContent),
      respond: response.resolve,
    });
    return response.promise;
  };
  // The DOM's order for one commit: the control's own action at its target,
  // then the form's as the `change` bubbles.
  const commit = (control, value) => {
    control.value = value;
    if (control === provider) controller.contextProviderChanged({ currentTarget: provider });
    if (control === model) controller.contextModelChanged();
    return controller.applyContext({ target: control });
  };
  return {
    controller, project, provider, model, effort, directory, continuity, pill, validations, popover, requests, commit,
  };
}
''';

const _contextSyncHarness =
    _contextControllerModule +
    r'''
const project = new FakeSelect('effective-context-project',
  [new Option('Alpha', 'p1'), new Option('Beta', 'p2')]);
const provider = new FakeSelect('effective-context-provider', [providerOption('claude'), providerOption('codex')]);
const model = new FakeSelect('effective-context-model-input',
  [new Option('Default · Opus', ''), new Option('Opus', 'opus'), new Option('Sonnet', 'sonnet')]);
const effort = new FakeSelect('effective-context-effort-input',
  [new Option('Default', ''), new Option('low', 'low'), new Option('high', 'high')]);
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
controller.conversationRevision = 3;

const recorded = (id) => globalThis.syncCalls.filter((call) => call.id === id);
const same = (left, right) => left.length === right.length && left.every((entry, i) => entry === right[i]);

// A provider change rewrites both dependent pickers.
provider.value = 'codex';
controller.contextProviderChanged({ currentTarget: provider });
assert(recorded('effective-context-model-input').length === 1, 'the model picker was not synced');
assert(same(recorded('effective-context-model-input')[0].labels, ['Default · GPT-5', 'GPT-5', 'GPT-5 mini']),
  'the model sync read the previous provider catalogue: '
    + JSON.stringify(recorded('effective-context-model-input')[0].labels));
assert(same(recorded('effective-context-effort-input')[0].labels, ['Default', 'medium', 'xhigh']),
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
    modelOptions: catalogues.claude,
    effortOptions: effortsFor('claude', 'opus'),
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
assert(same(recorded('effective-context-model-input')[0].labels, ['Default · Opus', 'Opus', 'Sonnet', 'Haiku']),
  'the reconciled model sync read the previous provider catalogue: '
    + JSON.stringify(recorded('effective-context-model-input')[0].labels));
assert(recorded('effective-context-model-input')[0].value === 'opus', 'the staged model was not selected');
assert(same(recorded('effective-context-effort-input')[0].labels, ['Default', ...FIVE]),
  'the reconciled effort sync read the previous provider catalogue: '
    + JSON.stringify(recorded('effective-context-effort-input')[0].labels));
assert(controller.conversationRevision === 7, 'the revision was not absorbed');
''';

const _applyOnChangeHarness =
    _contextControllerModule +
    r'''
const f = contextFixture();
const shown = () => f.validations.filter((validation) => !validation.hidden);

// Picking a model sends one request, on the displayed revision, and the pill
// reconciles from the answer.
const picked = f.commit(f.model, 'opus');
assert(f.requests.length === 1, 'picking a model sent ' + f.requests.length + ' requests');
assert(f.requests[0].method === 'PATCH' && f.requests[0].url === '/api/sessions/session-1/context',
  'the pick did not go to the context route: ' + f.requests[0].method + ' ' + f.requests[0].url);
assert(f.requests[0].body.model === 'opus', 'the pick did not carry the model');
assert(f.requests[0].body.conversation_revision === 3, 'the pick did not carry the displayed revision');
f.requests[0].respond(accepted(snapshot(4, { modelValue: 'opus', composer: 'claude · Opus' })));
await picked;
assert(f.pill.textContent === 'claude · Opus', 'the pill did not reconcile: ' + f.pill.textContent);
assert(f.model.value === 'opus', 'the model picker did not reconcile');
assert(f.controller.conversationRevision === 4, 'the returned revision was not absorbed');

// Default is no model at all, not an empty one.
const cleared = f.commit(f.model, '');
assert(f.requests[1].body.model === null, 'Default sent ' + JSON.stringify(f.requests[1].body.model));
f.requests[1].respond(accepted(snapshot(5)));
await cleared;

// A provider change rebuilds the pickers over the new catalogue first, then
// applies once.
const switched = f.commit(f.provider, 'codex');
assert(f.requests.length === 3, 'a provider change sent ' + (f.requests.length - 2) + ' requests');
assert(f.requests[2].body.provider === 'codex', 'the provider change did not carry the provider');
assert(f.requests[2].modelOptions.join() === 'Default · GPT-5,GPT-5,GPT-5 mini',
  'the request went out before the model picker was rebuilt: ' + f.requests[2].modelOptions.join());
f.requests[2].respond(accepted(snapshot(6, { provider: 'codex' })));
await switched;
assert(f.requests.length === 3, 'the provider change was applied more than once');

// A change made while another is in flight waits for it, then goes out on the
// revision it returned, carrying both changes. The first answer must not undo
// the waiting change.
const first = f.commit(f.model, 'gpt-5');
const second = f.commit(f.effort, 'xhigh');
assert(f.requests.length === 4, 'a second request was sent while the first was in flight');
f.requests[3].respond(accepted(snapshot(7, { provider: 'codex', modelValue: 'gpt-5' })));
await settle();
assert(f.requests.length === 5, 'the waiting change was never sent');
assert(f.requests[4].body.conversation_revision === 7, 'the waiting change did not carry the returned revision');
assert(f.requests[4].body.model === 'gpt-5' && f.requests[4].body.effort === 'xhigh',
  'the waiting change lost a field: ' + JSON.stringify(f.requests[4].body));
f.requests[4].respond(accepted(snapshot(8, { provider: 'codex', modelValue: 'gpt-5', effortValue: 'xhigh' })));
await Promise.all([first, second]);
assert(f.effort.value === 'xhigh' && f.model.value === 'gpt-5', 'the final context is not the second change');
assert(f.controller.conversationRevision === 8, 'the final revision was not absorbed');
assert(shown().length === 0, 'a serialised change reported a rejection');
assert(f.requests.length === 5, 'more requests than commits were sent');

// Enter in Directory commits through its `change`; the form submission it
// also triggers is held and sends nothing.
let held = false;
f.controller.holdContextSubmit({ preventDefault() { held = true; } });
assert(held && f.requests.length === 5, 'a directory submit was not held or sent a request');

// Picks made for one provider do not travel to another: the new provider
// would be asked for a model and effort it does not offer, and its next turn
// would fail.
const across = contextFixture();
across.controller.reconcileContext(snapshot(4, { modelValue: 'opus', effortValue: 'high' }));
const switching = across.commit(across.provider, 'codex');
assert(across.requests[0].body.model === null && across.requests[0].body.effort === null,
  'a provider change carried the old provider picks: ' + JSON.stringify(across.requests[0].body));
across.requests[0].respond(accepted(snapshot(5, { provider: 'codex' })));
await switching;

// A conversation-state refresh landing between a waiting commit and its send
// (a running turn emits them) must not revert the controls the commit sends.
const racing = contextFixture();
for (const name of ['renderQueue', 'renderRequestStrip', 'showRecovery', 'updateSendState',
  'handleVisibleReadBoundary', 'setSaveStatus']) {
  racing.controller[name] = () => {};
}
const pickA = racing.commit(racing.model, 'opus');
const pickB = racing.commit(racing.effort, 'high');
const refresh = racing.controller.refreshConversationState();
assert(racing.requests[1].method === 'GET', 'the refresh did not read the conversation state');
racing.requests[1].respond(accepted({ ...snapshot(5), queue: [], records: [], activity: {} }));
await refresh;
assert(racing.model.value === 'opus' && racing.effort.value === 'high',
  'a refresh reverted controls a commit is about to send');
// The first commit's answer predates the refresh; the waiting commit goes out
// on the newer revision.
racing.requests[0].respond(accepted(snapshot(4, { modelValue: 'opus' })));
await settle();
const waiting = racing.requests[2];
assert(waiting && waiting.body.model === 'opus' && waiting.body.effort === 'high',
  'the waiting commit lost a change: ' + JSON.stringify(waiting?.body));
assert(waiting.body.conversation_revision === 5, 'the waiting commit used a stale revision');
waiting.respond(accepted(snapshot(6, { modelValue: 'opus', effortValue: 'high' })));
await Promise.all([pickA, pickB]);
assert(racing.model.value === 'opus' && racing.effort.value === 'high', 'the final context is not both changes');
''';

const _rejectedApplyHarness =
    _contextControllerModule +
    r'''
const f = contextFixture();
const recorded = (id) => globalThis.syncCalls.filter((call) => call.id === id);
const messages = () => f.validations.map((validation) => (validation.hidden ? '' : validation.textContent));

// A refused directory says why and stays in the field, marked invalid.
f.directory.value = '/nope';
const directory = f.controller.applyContext({ target: f.directory });
assert(f.requests[0].body.directory === '/nope', 'the typed directory was not sent');
f.requests[0].respond(refused('Directory does not exist'));
await directory;
assert(messages().every((message) => message === 'Directory does not exist'), 'the refusal was not shown: '
  + JSON.stringify(messages()));
assert(f.directory.value === '/nope', 'the typed directory was discarded: ' + f.directory.value);
assert(f.directory.attributes['aria-invalid'] === 'true', 'the refused directory was not marked invalid');

// A refused pick goes back to the applied value, through the enhancer's sync.
// The refused directory is not an applied value, so it does not ride along.
const model = f.commit(f.model, 'opus');
assert(f.requests[1].body.directory === '/tmp/alpha',
  'an unrelated change carried the refused directory: ' + f.requests[1].body.directory);
f.requests[1].respond(refused('Model not accepted'));
await model;
assert(f.model.value === '', 'the model picker kept a refused value: ' + f.model.value);
assert(recorded('effective-context-model-input').at(-1).value === '', 'the restored model was not synced');
assert(messages().every((message) => message === 'Model not accepted'), 'the second refusal was not shown');
assert(f.directory.value === '/nope' && f.directory.attributes['aria-invalid'] === 'true',
  'an unrelated refusal cleared the typed directory');

// The next accepted change clears the refusal and the invalid mark.
const effort = f.commit(f.effort, 'high');
f.requests[2].respond(accepted(snapshot(4, { effortValue: 'high' })));
await effort;
assert(!('aria-invalid' in f.directory.attributes), 'the invalid mark outlived an accepted change');
assert(f.directory.value === '/tmp/alpha', 'the directory does not show the applied value: ' + f.directory.value);
assert(messages().every((message) => message === ''), 'the refusal outlived an accepted change');
assert(globalThis.toasts.length === 0, 'a refusal shown in the open popover was also toasted');

// Before the first conversation-state snapshot, the server-rendered selection
// is the applied context a refusal restores.
const early = contextFixture();
early.controller.appliedContextSnapshot = null;
early.controller.seedAppliedContext();
const earlyPick = early.commit(early.model, 'opus');
early.requests[0].respond(refused('Model not accepted'));
await earlyPick;
assert(early.model.value === '', 'a refusal before the first snapshot left the refused value shown');

// Another response (a mark-read, a queue edit) can advance the revision past
// the applied snapshot's; restoring after a refusal must not roll it back.
early.controller.conversationRevision = 9;
const advanced = early.commit(early.model, 'sonnet');
early.requests[1].respond(refused('Model not accepted'));
await advanced;
assert(early.controller.conversationRevision === 9,
  'a refusal rolled the revision back to ' + early.controller.conversationRevision);
const after = early.commit(early.effort, 'high');
assert(early.requests[2].body.conversation_revision === 9, 'the next commit carried a rolled-back revision');
early.requests[2].respond(accepted(snapshot(10, { effortValue: 'high' })));
await after;

// Leaving Directory by clicking outside closes the popover before its change
// fires; the refusal must still reach the reader.
early.popover.hidden = true;
early.directory.value = '/gone';
const closed = early.controller.applyContext({ target: early.directory });
early.requests[3].respond(refused('Directory does not exist'));
await closed;
assert(globalThis.toasts.join() === 'Directory does not exist',
  'a refusal for a closed popover was not shown: ' + JSON.stringify(globalThis.toasts));
''';

const _continuityHarness =
    _contextControllerModule +
    r'''
const f = contextFixture();
assert(f.continuity.hidden, 'the notice showed with nothing changed');

const toCodex = f.commit(f.provider, 'codex');
assert(f.continuity.hidden, 'the notice showed for a provider change not yet applied');
f.requests[0].respond(accepted(snapshot(4, { provider: 'codex', continuityHidden: null })));
await toCodex;
assert(!f.continuity.hidden, 'the notice stayed hidden after a provider change was applied');

const back = f.commit(f.provider, 'claude');
f.requests[1].respond(accepted(snapshot(5, { provider: 'claude', continuityHidden: true })));
await back;
assert(f.continuity.hidden, 'the notice stayed after the last-run provider was applied again');

// A refused change restores the applied context, and the notice with it.
const refusedSwitch = f.commit(f.provider, 'codex');
f.requests[2].respond(refused('Provider unavailable'));
await refusedSwitch;
assert(f.continuity.hidden, 'the notice showed for a refused provider change');
''';

const _modelCatalogueHarness =
    _contextControllerModule +
    r'''
const f = contextFixture();
const labels = (select) => select.options.map((option) => option.textContent);
const same = (left, right) => left.length === right.length && left.every((entry, i) => entry === right[i]);

// A provider switch renders that provider's picker exactly as the server built
// it – its names and its Default label – with no second list on the page.
f.provider.value = 'codex';
f.controller.contextProviderChanged({ currentTarget: f.provider });
assert(same(labels(f.model), ['Default · GPT-5', 'GPT-5', 'GPT-5 mini']), 'codex models: ' + labels(f.model));
assert(same(labels(f.effort), ['Default', 'medium', 'xhigh']), 'codex efforts: ' + labels(f.effort));
f.provider.value = 'claude';
f.controller.contextProviderChanged({ currentTarget: f.provider });
assert(same(labels(f.model), ['Default · Opus', 'Opus', 'Sonnet', 'Haiku']), 'claude models: ' + labels(f.model));

const withEffort = f.commit(f.effort, 'high');
f.requests[0].respond(accepted(snapshot(4, { effortValue: 'high' })));
await withEffort;
assert(f.effort.value === 'high', 'the effort was not applied');

// Haiku reports no efforts: Effort offers only Default, locks, and the apply
// carries no effort rather than one the model cannot take.
const haiku = f.commit(f.model, 'haiku');
assert(same(labels(f.effort), ['Default']), 'Haiku offered efforts: ' + labels(f.effort));
assert(f.effort.disabled === true, 'Effort stayed editable for a model without efforts');
assert(f.requests[1].body.model === 'haiku' && f.requests[1].body.effort === null,
  'picking Haiku applied ' + JSON.stringify(f.requests[1].body));
f.requests[1].respond(accepted(snapshot(5, { modelValue: 'haiku', effortEditable: false })));
await haiku;
assert(f.effort.disabled === true, 'the reconcile re-enabled Effort for Haiku');

// Sonnet offers its own five efforts again.
const sonnet = f.commit(f.model, 'sonnet');
assert(same(labels(f.effort), ['Default', 'low', 'medium', 'high', 'xhigh', 'max']), 'Sonnet efforts: ' + labels(f.effort));
assert(f.effort.disabled === false, 'Effort stayed locked for Sonnet');
f.requests[2].respond(accepted(snapshot(6, { modelValue: 'sonnet' })));
await sonnet;

// A staged model the catalogue does not list arrives as the server's own
// option and stays selected, with the effort staged beside it.
const offCatalogue = { value: 'claude-sonnet-4-5', label: 'claude-sonnet-4-5', efforts: JSON.stringify(
  [{ value: '', label: 'Default' }, { value: 'high', label: 'high' }]), effortEditable: 'true' };
f.controller.reconcileContext(snapshot(7, {
  modelValue: 'claude-sonnet-4-5',
  effortValue: 'high',
  modelOptions: [...catalogues.claude, offCatalogue],
  effortOptions: [{ value: '', label: 'Default' }, { value: 'high', label: 'high' }],
}));
assert(f.model.value === 'claude-sonnet-4-5', 'the staged model was dropped: ' + f.model.value);
assert(labels(f.model).at(-1) === 'claude-sonnet-4-5', 'the staged model is not its own option');
assert(f.effort.value === 'high', 'the staged effort was dropped');
''';
