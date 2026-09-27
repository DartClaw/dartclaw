import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_shell_controller.js');

  test('rail view state classifies rows, formats times and survives bad storage', () async {
    await expectNodeHarness(_inboxViewHarness, [(await controller).absolute.uri.toString()]);
  });

  test('select mode reaches project rows and keeps their bulk settle selection', () async {
    await expectNodeHarness(_projectSelectionHarness, [(await controller).absolute.uri.toString()]);
  });

  test('rail width defaults to 280, clamps 240-420 and persists every change', () async {
    await expectNodeHarness(_resizeHarness, [(await controller).absolute.uri.toString()]);
  });

  // The rail row and the topbar crumb name the model by the inbox row's
  // server-built `model_label`, the label the composer uses – never the raw id.
  test('rail rows and the topbar crumb name the model by its catalogue label', () async {
    final source = (await controller).readAsStringSync();
    expect(source, contains("[entry.provider, entry.model_label].filter(Boolean).join(' · ')"));
    expect(source, contains('for (const value of [entry.provider, entry.model_label].filter(Boolean))'));
    expect(source, isNot(contains('entry.model]')));
  });
}

/// Shared prelude: the controller is a Stimulus class with one shared-module
/// import, so both harnesses stub the same two seams and instantiate it without
/// `connect()`.
const _prelude = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.storage = new Map();
globalThis.localStorage = {
  getItem: (key) => (globalThis.storage.has(key) ? globalThis.storage.get(key) : null),
  setItem: (key, value) => globalThis.storage.set(key, String(value)),
  removeItem: (key) => globalThis.storage.delete(key),
};
globalThis.documentElement = { style: { properties: {}, setProperty(name, value) { this.properties[name] = value; } }, dataset: {} };
globalThis.handleAttributes = {};
globalThis.handle = {
  dataset: {},
  getAttribute: (name) => globalThis.handleAttributes[name] ?? null,
  setAttribute: (name, value) => { globalThis.handleAttributes[name] = value; },
  addEventListener() {},
};
globalThis.document = {
  documentElement: globalThis.documentElement,
  body: { addEventListener() {}, removeEventListener() {} },
  addEventListener() {},
  removeEventListener() {},
  getElementById: () => null,
  querySelector: (selector) => (selector === '.sidebar-resize-handle' ? globalThis.handle : null),
  querySelectorAll: () => [],
};

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const apiQs = () => '';
const applyIdenticons = () => {};
const beginSessionDraftMutation = () => {};
const closeAllCustomSelects = () => {};
const conversationDraftSessionIds = async () => [];
const confirmDialog = async () => true;
const dismissRestartBannerState = () => {};
const endSessionDraftMutation = () => {};
const getApiToken = () => null;
const initCustomSelects = () => {};
const isAtBottom = () => false;
const queueToast = () => {};
const readHtmxErrorMessage = () => '';
const reconcileRestartBanner = () => {};
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showToast = () => {};
const syncSidebarSessionTitle = () => {};
const syncRestartBannerAfterSwap = () => {};
const TOAST_QUEUE_KEY = 'toast-queue';
`);

const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
''';

const _inboxViewHarness =
    _prelude +
    r'''
// A row's state order decides both its dot and its status group, so the most
// urgent state has to win over every state it coexists with.
const entry = { waiting: true, running: true, unread: true, failed: false, done: false, local_draft: false };
assert(controller.inboxStates(entry)[0] === 'waiting', 'a waiting row did not lead with its attention state');
assert(controller.inboxStates({ done: true, unread: true })[0] === 'unread',
  'an unread row reported itself as merely done');

// Show filters select on the row's own flags; "All" never hides anything.
assert(controller.matchesInboxFilter({ failed: true }, 'all'), 'the All filter hid a row');
assert(controller.matchesInboxFilter({ failed: true }, 'failed'), 'the Failed filter dropped a failed row');
assert(!controller.matchesInboxFilter({ failed: true }, 'waiting'), 'the Waiting filter kept a failed row');
assert(controller.matchesInboxFilter({ local_draft: true }, 'drafts'), 'the Drafts filter dropped a device draft');
assert(!controller.matchesInboxFilter({ unread: true }, 'drafts'), 'the Drafts filter kept a non-draft row');

// The rail reads elapsed time for a running turn and relative time otherwise.
const now = Date.now();
assert(controller.relativeLabel(new Date(now - 30 * 1000).toISOString()) === 'now', 'sub-minute age did not read as now');
assert(controller.relativeLabel(new Date(now - 4 * 60 * 1000).toISOString()) === '4m', 'minutes did not read as Nm');
assert(controller.relativeLabel(new Date(now - 3 * 3600 * 1000).toISOString()) === '3h', 'hours did not read as Nh');
assert(controller.relativeLabel(new Date(now - 3 * 86400 * 1000).toISOString()) === '3d', 'days did not read as Nd');
assert(controller.elapsedLabel(new Date(now - 72 * 1000).toISOString()) === '1m12s',
  'a running turn did not read as minutes and seconds');
assert(controller.elapsedLabel(new Date(now - 3734 * 1000).toISOString()) === '1h02m',
  'an hour-long turn did not compact to hours and minutes');

// View state is per device. A value the menu cannot produce falls back rather
// than filtering the rail down to nothing the user can undo.
globalThis.storage.set('dartclaw-inbox-view', '{"filter":"bogus","group":"project","scope":"p1"}');
let view = controller.loadInboxView();
assert(view.filter === 'all', 'an unknown stored filter was applied');
assert(view.group === 'project', 'a valid stored grouping was discarded');
assert(view.scope === 'p1', 'a stored scope was discarded');
assert(view.selectMode === false, 'select mode was restored from storage');

controller.inboxView = null;
globalThis.storage.set('dartclaw-inbox-view', 'not json');
view = controller.loadInboxView();
assert(view.filter === 'all' && view.group === 'none' && view.scope === '',
  'unreadable view state did not fall back to the default view');

controller.inboxView.filter = 'waiting';
controller.inboxView.selectMode = true;
controller.persistInboxView();
const persisted = JSON.parse(globalThis.storage.get('dartclaw-inbox-view'));
assert(persisted.filter === 'waiting', 'the chosen filter was not persisted');
assert(!('selectMode' in persisted), 'select mode was persisted as a preference');

// Only the view-options command toggles select mode. The rail body carries
// `data-inbox-select-mode` as its own state, so a click on a row — or on the
// checkbox — reaches the document handler with that attribute above it.
const clickOn = (selectors) => ({
  target: { matches: () => false, closest: (selector) => (selectors.includes(selector) ? {} : null) },
  preventDefault() {},
  detail: 1,
});
controller.inboxView.selectMode = true;
controller.handleDocumentClick(clickOn(['[data-inbox-select-mode]']));
assert(controller.loadInboxView().selectMode === true, 'a click inside the list left select mode');
controller.handleDocumentClick(clickOn(['[data-inbox-select-toggle]']));
assert(controller.loadInboxView().selectMode === false, 'the view-options command did not leave select mode');

// Every page now carries enhanced selects, and a closed one's menu is a `.pop`
// that stays in the DOM. Escape has to reach select mode past it. One node
// stands for that DOM; the matcher reads the selector's own :not() clauses.
const closedMenu = { classes: ['pop', 'card', 'card-elevated', 'custom-select-menu'], hidden: false };
const matchPop = (selector) => {
  if (!selector.startsWith('.pop')) return null;
  const excluded = [...selector.matchAll(/:not\(\.([a-z-]+)\)/g)].map((match) => match[1]);
  return excluded.some((name) => closedMenu.classes.includes(name)) ? null : closedMenu;
};
const topbarMenu = { hidden: false };
globalThis.document.querySelector = (selector) => {
  if (selector === '[data-topbar-menu]') return topbarMenu;
  if (selector.includes(':not([hidden])') && closedMenu.hidden) return null;
  return matchPop(selector);
};
controller.inboxView.selectMode = true;
controller.handleDocumentKeydown({ key: 'Escape' });
assert(controller.loadInboxView().selectMode === false, 'a closed select menu swallowed Escape');

// The click path needs the same discriminator: an open select menu overlays the
// shell popover it was opened from, so a row click there is outside every shell
// popover and has to dismiss them.
controller.handleDocumentClick({
  target: { matches: () => false, closest: matchPop },
  preventDefault() {},
  detail: 1,
});
assert(topbarMenu.hidden === true, 'a click on a custom-select row left the shell popover open');
''';

const _resizeHarness =
    _prelude +
    r'''
const width = () => Number.parseInt(globalThis.documentElement.style.properties['--sidebar-w'], 10);

controller.applySidebarWidth(280, false);
assert(width() === 280, 'the rail did not take the 280px default');
assert(globalThis.storage.get('dartclaw-sidebar-width') === undefined,
  'a non-persisting application still wrote the stored width');

controller.applySidebarWidth(120, true);
assert(width() === 240, 'the rail was allowed below its 240px floor');
controller.applySidebarWidth(900, true);
assert(width() === 420, 'the rail was allowed above its 420px ceiling');
assert(globalThis.storage.get('dartclaw-sidebar-width') === '420', 'the dragged width was not persisted');
assert(globalThis.handleAttributes['aria-valuenow'] === '420',
  'the separator did not report its new value to assistive technology');

controller.applySidebarWidth(317.6, true);
assert(width() === 318, 'a fractional pointer position was not rounded to a whole pixel');

// The collapse toggle hands the width back and records the choice, so a reload
// does not reopen a rail the operator closed.
controller.setRailCollapsed(true);
assert(globalThis.documentElement.dataset.railCollapsed === 'true', 'collapsing did not mark the document');
assert(globalThis.storage.get('dartclaw-rail-collapsed') === 'true', 'the collapsed rail was not remembered');
controller.setRailCollapsed(false);
assert(globalThis.documentElement.dataset.railCollapsed === 'false', 'expanding did not clear the marker');
''';

const _projectSelectionHarness =
    _prelude +
    r'''
const attributes = {};
const body = { setAttribute(name, value) { attributes[name] = value; } };
const projectCheckbox = { checked: false };
const settleButton = { disabled: true };
const selectedCount = { textContent: '' };
const bulk = {
  hidden: true,
  querySelector(selector) {
    return selector === '[data-inbox-selected-count]' ? selectedCount : settleButton;
  },
};
globalThis.document.querySelector = (selector) => ({
  '.sidebar-body': body,
  '[data-inbox-bulk]': bulk,
})[selector] || null;
globalThis.document.querySelectorAll = (selector) =>
  selector === '[data-inbox-select]:checked' && projectCheckbox.checked ? [projectCheckbox] : [];

controller.setSelectMode(true);
assert(attributes['data-inbox-select-mode'] === 'true', 'project rows did not enter select mode');
projectCheckbox.checked = true;
controller.syncBulkBar();
assert(selectedCount.textContent === '1 selected', 'project row was not counted');
assert(settleButton.disabled === false, 'project row did not enable bulk settle');
controller.setSelectMode(false);
assert(projectCheckbox.checked === false, 'project selection remained checked');
''';
