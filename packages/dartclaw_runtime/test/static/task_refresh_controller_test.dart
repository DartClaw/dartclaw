import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_tasks_controller.js');

  test('live task detail refresh initializes replacement HTMX controls', () async {
    await expectNodeHarness(_taskRefreshHarness, [(await controller).absolute.uri.toString()]);
  });
}

const _taskRefreshHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const detailPage = {
  querySelector(selector) {
    if (selector === '.task-meta-card .status-badge') return { textContent: 'Running' };
    return null;
  },
};
const nextContent = { id: 'tasks-content' };
let replacedContent = null;
const currentContent = {
  replaceWith(content) { replacedContent = content; },
};

globalThis.window = {
  location: { pathname: '/tasks/task-1', search: '' },
  dartclaw: {
    ui: { initCustomSelects() {} },
    shell: {},
  },
};
globalThis.Stimulus = { Controller: class {} };
globalThis.document = {
  querySelector(selector) {
    if (selector === '.task-detail-page') return detailPage;
    return null;
  },
  querySelectorAll() { return []; },
  getElementById(id) { return id === 'tasks-content' ? currentContent : null; },
};
globalThis.DOMParser = class {
  parseFromString() {
    return { getElementById(id) { return id === 'tasks-content' ? nextContent : null; } };
  }
};
globalThis.fetch = async () => ({ ok: true, text: async () => '<main id="tasks-content"></main>' });
let refresh;
globalThis.setInterval = callback => { refresh = callback; return 1; };
globalThis.clearInterval = () => {};
let processedContent = null;
globalThis.htmx = { process(content) { processedContent = content; } };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(
  "import { updateRunningTasksSection, updateRunningWorkflowsSection } from './sidebar_sections.js';",
  'const updateRunningTasksSection = (items) => items; const updateRunningWorkflowsSection = () => {};',
);
await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
window.dartclaw.tasksControllerApi.onLoad();
await refresh();

assert(replacedContent === nextContent, 'live refresh did not replace the task content');
assert(processedContent === nextContent, 'replacement task content was not initialized by HTMX');
''';
