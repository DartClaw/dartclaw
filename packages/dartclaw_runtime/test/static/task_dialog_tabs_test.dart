import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_tasks_controller.js');

  test('task dialog tabs switch panels without rewriting form actions', () async {
    await expectNodeHarness(_harness, [(await controller).absolute.uri.toString()]);
  });
}

const _harness = r'''
import { readFile } from 'node:fs/promises';

class ClassList {
  constructor(...names) { this.names = new Set(names); }
  toggle(name, enabled) { if (enabled) this.names.add(name); else this.names.delete(name); }
  contains(name) { return this.names.has(name); }
}

function makeTab(value, active) {
  return {
    dataset: { taskTab: value },
    classList: new ClassList(...(active ? ['active'] : [])),
    attributes: { 'aria-selected': active ? 'true' : 'false', tabindex: active ? '0' : '-1' },
    setAttribute(name, value) { this.attributes[name] = value; },
    focus() { focusedTab = value; },
  };
}
let focusedTab = null;
const singleTab = makeTab('single', true);
const workflowTab = makeTab('workflow', false);
const singlePanel = { dataset: { taskPanel: 'single' }, classList: new ClassList('active') };
const workflowPanel = { dataset: { taskPanel: 'workflow' }, classList: new ClassList() };
const singleActions = { dataset: { taskAction: 'single' }, hidden: false };
const workflowActions = { dataset: { taskAction: 'workflow' }, hidden: true };
let click;
let keydown;
let eventSourceCloseCalls = 0;
const dialog = {
  dataset: {},
  matches(selector) { return selector === '#new-task-dialog'; },
  addEventListener(name, listener) {
    if (name === 'click') click = listener;
    if (name === 'keydown') keydown = listener;
  },
  querySelectorAll(selector) {
    if (selector === '[data-task-tab]') return [singleTab, workflowTab];
    if (selector === '[data-task-panel]') return [singlePanel, workflowPanel];
    if (selector === '[data-task-action]') return [singleActions, workflowActions];
    return [];
  },
};

globalThis.window = {
  location: { pathname: '/tasks', href: 'http://localhost/tasks', search: '' },
  dartclaw: {
    ui: { initCustomSelects() {}, showToast() {} },
    shell: {},
    workflowsControllerApi: {},
  },
};
globalThis.document = {
  body: { dataset: {}, addEventListener() {} },
  getElementById(id) { return id === 'new-task-dialog' ? dialog : null; },
  querySelector(selector) { return selector === '[data-tasks-enabled]' ? {} : null; },
  querySelectorAll() { return []; },
};
globalThis.Stimulus = { Controller: class {} };
globalThis.EventSource = class {
  close() { eventSourceCloseCalls += 1; }
};

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(
  "import { updateRunningTasksSection, updateRunningWorkflowsSection } from './sidebar_sections.js';",
  'const updateRunningTasksSection = (items) => items; const updateRunningWorkflowsSection = (items) => items;',
);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const pageController = new module.default();
pageController.element = { matches() { return false; } };
pageController.connect();
const controller = new module.default();
controller.element = dialog;
controller.connect();

if (typeof click !== 'function') throw new Error('tab listener was not installed');
click({ target: { closest: () => workflowTab } });
if (!workflowTab.classList.contains('active') || singleTab.classList.contains('active')) {
  throw new Error('workflow tab did not become active');
}
if (!workflowPanel.classList.contains('active') || singlePanel.classList.contains('active')) {
  throw new Error('workflow panel did not become active');
}
if (!singleActions.hidden || workflowActions.hidden) throw new Error('workflow actions did not become active');
if (workflowTab.attributes['aria-selected'] !== 'true' || singleTab.attributes['aria-selected'] !== 'false') {
  throw new Error('tab switching did not update the selected state');
}
if (workflowTab.attributes.tabindex !== '0' || singleTab.attributes.tabindex !== '-1') {
  throw new Error('tab switching did not update keyboard focus order');
}
let prevented = false;
keydown({
  key: 'ArrowLeft',
  target: { closest: () => workflowTab },
  preventDefault() { prevented = true; },
});
if (!prevented || focusedTab !== 'single') throw new Error('arrow-key navigation did not focus the adjacent tab');
if (!singlePanel.classList.contains('active') || workflowPanel.classList.contains('active')) {
  throw new Error('arrow-key navigation did not activate the adjacent panel');
}
if (singleActions.hidden || !workflowActions.hidden) throw new Error('single-task actions did not become active');
if ('textContent' in workflowTab || 'textContent' in singleTab) {
  throw new Error('tab switching rewrote an action label');
}
controller.disconnect();
if (eventSourceCloseCalls !== 0) throw new Error('disconnecting the dialog closed the page task event stream');
pageController.disconnect();
if (eventSourceCloseCalls !== 1) throw new Error('disconnecting the page did not close its task event stream');
''';
