import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_memory_controller.js');

  test('file controls preserve programmatic state and keyboard behavior', () async {
    await expectNodeHarness(_accessibilityHarness, [(await controller).absolute.uri.toString()]);
  });
}

const _accessibilityHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

class ClassList {
  constructor(...names) { this.names = new Set(names); }
  add(...names) { names.forEach((name) => this.names.add(name)); }
  remove(...names) { names.forEach((name) => this.names.delete(name)); }
  toggle(name, force) {
    const active = force === undefined ? !this.names.has(name) : force;
    if (active) this.names.add(name); else this.names.delete(name);
    return active;
  }
  contains(name) { return this.names.has(name); }
}

const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => stored.get(key) ?? null,
  setItem: (key, value) => stored.set(key, value),
};
globalThis.window = {
  marked: { parse: () => '<h1>Title</h1><h4>Nested</h4>' },
  DOMPurify: { sanitize: (html) => html },
};
globalThis.Stimulus = { Controller: class {} };
globalThis.CSS = { escape: (value) => value };

const createdHeadings = [];
globalThis.document = {
  createElement(tagName) {
    const node = {
      tagName: tagName.toUpperCase(),
      attributes: [],
      childNodes: [],
      setAttribute(name, value) { this.attributes.push({ name, value }); },
      append(...children) { this.childNodes.push(...children); },
    };
    createdHeadings.push(node);
    return node;
  },
};

const source = await readFile(new URL(process.argv[1]), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();

function makeTab(id) {
  const attributes = new Map([['aria-selected', id === 'tab-memory' ? 'true' : 'false'], ['tabindex', id === 'tab-memory' ? '0' : '-1']]);
  return {
    dataset: { tab: id },
    classList: new ClassList('tab', ...(id === 'tab-memory' ? ['active'] : [])),
    focused: false,
    attributes,
    setAttribute(name, value) { attributes.set(name, value); },
    getAttribute(name) { return attributes.get(name) ?? null; },
    closest(selector) {
      if (selector === '.card') return card;
      if (selector === '[role="tab"]') return this;
      return null;
    },
    click() { controller.switchTab({ currentTarget: this }); },
    focus() { tabs.forEach((tab) => { tab.focused = false; }); this.focused = true; },
    scrollIntoView() { this.scrolled = true; },
  };
}

function makePanel(id) {
  return {
    id,
    classList: new ClassList('tab-panel', ...(id === 'tab-memory' ? ['active'] : [])),
    querySelector: () => null,
  };
}

const tabs = ['tab-memory', 'tab-errors', 'tab-learnings', 'tab-archive'].map(makeTab);
const panels = tabs.map((tab) => makePanel(tab.dataset.tab));
const card = {
  querySelectorAll(selector) {
    if (selector === '.tab') return tabs;
    if (selector === '.tab-panel') return panels;
    return [];
  },
  querySelector(selector) { return panels.find((panel) => '#' + panel.id === selector) ?? null; },
};
const tablist = {
  contains: (node) => tabs.includes(node),
  querySelectorAll: (selector) => selector === '[role="tab"]' ? tabs : [],
};

let prevented = false;
controller.navigateTabs({
  key: 'ArrowRight',
  currentTarget: tablist,
  target: tabs[0],
  preventDefault() { prevented = true; },
});
assert(prevented, 'ArrowRight was not handled');
assert(tabs[1].focused, 'ArrowRight did not move focus to errors.md');
assert(tabs[1].getAttribute('aria-selected') === 'true', 'ArrowRight did not select errors.md');
assert(tabs[1].getAttribute('tabindex') === '0', 'selected tab is not in the tab order');
assert(tabs[0].getAttribute('tabindex') === '-1', 'previous tab stayed in the tab order');

controller.navigateTabs({ key: 'End', currentTarget: tablist, target: tabs[1], preventDefault() {} });
assert(tabs[3].focused && tabs[3].getAttribute('aria-selected') === 'true', 'End did not select the final tab');
controller.navigateTabs({ key: 'Home', currentTarget: tablist, target: tabs[3], preventDefault() {} });
assert(tabs[0].focused && tabs[0].getAttribute('aria-selected') === 'true', 'Home did not select the first tab');
controller.navigateTabs({ key: 'ArrowLeft', currentTarget: tablist, target: tabs[0], preventDefault() {} });
assert(tabs[3].focused && tabs[3].getAttribute('aria-selected') === 'true', 'ArrowLeft did not wrap to the final tab');

function makeToggle(mode) {
  const attributes = new Map();
  return {
    dataset: { mode },
    classList: new ClassList('toggle-btn'),
    setAttribute(name, value) { attributes.set(name, value); },
    getAttribute(name) { return attributes.get(name) ?? null; },
    closest: () => toggleGroup,
  };
}
const toggles = [makeToggle('raw'), makeToggle('rendered')];
const toggleGroup = { querySelectorAll: () => toggles };
controller.element = { querySelectorAll: (selector) => selector === '.memory-preview[data-loaded]' ? [] : toggles };
stored.set('dartclaw-memory-view', 'rendered');
controller.initMemoryViewToggle();
assert(toggles[0].getAttribute('aria-pressed') === 'false', 'Raw initialized as pressed');
assert(toggles[1].getAttribute('aria-pressed') === 'true', 'Rendered did not initialize as pressed');
controller.toggleView({ currentTarget: toggles[1] });
assert(toggles[0].getAttribute('aria-pressed') === 'false', 'Raw stayed pressed');
assert(toggles[1].getAttribute('aria-pressed') === 'true', 'Rendered was not pressed');

const replacements = [];
const headings = [
  { tagName: 'H1', attributes: [], childNodes: ['Title'], replaceWith: (node) => replacements.push(node) },
  { tagName: 'H4', attributes: [], childNodes: ['Nested'], replaceWith: (node) => replacements.push(node) },
];
const preview = {
  dataset: { rawContent: '# Title' },
  querySelectorAll: () => headings,
  set innerHTML(value) { this.rendered = value; },
  set textContent(value) { this.raw = value; },
};
controller.applyMemoryViewMode(preview);
assert(replacements.map((node) => node.tagName).join(',') === 'H3,H6', 'rendered headings were not demoted: ' + replacements.map((node) => node.tagName));
assert(preview.rendered === '<h1>Title</h1><h4>Nested</h4>', 'sanitized Markdown was not rendered');
''';
