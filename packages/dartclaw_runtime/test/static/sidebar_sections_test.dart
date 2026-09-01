import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('sidebar_sections.js');

  test('dynamic sidebar sections keep Running, Workflows, Chats order', () async {
    await expectNodeHarness(_sidebarSectionsHarness, [(await controller).absolute.uri.toString()]);
  });
}

const _sidebarSectionsHarness = r'''
import { readFile } from 'node:fs/promises';

class Element {
  constructor(id = '') {
    this.id = id;
    this.children = [];
    this.parentNode = null;
    this.dataset = {};
    this.innerHTML = '';
  }

  get nextElementSibling() {
    if (!this.parentNode) return null;
    const index = this.parentNode.children.indexOf(this);
    return this.parentNode.children[index + 1] || null;
  }

  insertBefore(child, reference) {
    child.remove();
    const index = reference ? this.children.indexOf(reference) : -1;
    this.children.splice(index < 0 ? this.children.length : index, 0, child);
    child.parentNode = this;
  }

  replaceWith(replacement) {
    if (!this.parentNode) return;
    const parent = this.parentNode;
    const index = parent.children.indexOf(this);
    this.parentNode = null;
    replacement.remove();
    parent.children[index] = replacement;
    replacement.parentNode = parent;
  }

  remove() {
    if (!this.parentNode) return;
    const index = this.parentNode.children.indexOf(this);
    if (index >= 0) this.parentNode.children.splice(index, 1);
    this.parentNode = null;
  }

  querySelector(selector) {
    if (selector === '.sidebar-chat-section') return findById(this, 'chats');
    return null;
  }
}

function findById(root, id) {
  if (root.id === id) return root;
  for (const child of root.children) {
    const found = findById(child, id);
    if (found) return found;
  }
  return null;
}

function assertOrder(body) {
  const order = body.children.map((child) => child.id).join(',');
  if (order !== 'sidebar-running,sidebar-workflows,chats') {
    throw new Error('unexpected sidebar order: ' + order);
  }
}

const sidebar = new Element('sidebar');
const body = new Element('sidebar-body');
const chats = new Element('chats');
sidebar.insertBefore(body, null);
body.insertBefore(chats, null);

globalThis.window = { htmx: { process() {} } };
globalThis.document = {
  getElementById(id) { return findById(sidebar, id); },
  createElement() { return new Element(); },
};

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(
  "import { escapeHtml, sanitizeClassToken } from './shared.js';",
  "const escapeHtml = (value) => String(value); const sanitizeClassToken = (value) => String(value);",
);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const tasks = [{ id: 'task', title: 'Task', status: 'running' }];
const workflows = [{ id: 'workflow', definitionName: 'Workflow', completedSteps: 0, totalSteps: 1 }];

module.updateRunningWorkflowsSection(workflows);
module.updateRunningTasksSection(tasks);
assertOrder(body);

module.updateRunningTasksSection([]);
module.updateRunningWorkflowsSection([]);
module.updateRunningTasksSection(tasks);
module.updateRunningWorkflowsSection(workflows);
assertOrder(body);
''';
