import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_tasks_controller.js');

  test('starting a task replaces detail content without reloading', () async {
    await expectNodeHarness(_taskStartHarness, [controller.absolute.uri.toString(), 'success']);
  });

  for (final mode in ['non-ok', 'missing-content', 'rejected']) {
    test('starting a task surfaces a failed detail refresh ($mode)', () async {
      await expectNodeHarness(_taskStartHarness, [controller.absolute.uri.toString(), mode]);
    });
  }
}

const _taskStartHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

let clickListener;
const mode = process.argv[2];
const toasts = [];
const startButton = {
  dataset: {},
  disabled: false,
  addEventListener(type, listener) {
    if (type === 'click') clickListener = listener;
  },
};

const detailPage = {
  getAttribute(name) { return name === 'data-task-id' ? 'task-1' : null; },
  querySelector(selector) {
    if (selector === '[data-task-start]') return startButton;
    return null;
  },
};

let replacement = null;
const currentContent = {
  replaceWith(next) { replacement = next; },
};
const nextContent = { id: 'main-content', state: 'queued' };

globalThis.Stimulus = { Controller: class {} };
globalThis.window = {
  location: {
    pathname: '/tasks/task-1',
    search: '?token=test',
    reload() { throw new Error('task start triggered a full-page reload'); },
  },
  dartclaw: {
    ui: { showToast(level, message) { toasts.push({ level, message }); }, initCustomSelects() {} },
    shell: { apiQs: () => '?token=test', renderMarkdown() {} },
  },
};
globalThis.document = {
  querySelector(selector) {
    if (selector === '.task-detail-page') return detailPage;
    return null;
  },
  querySelectorAll() { return []; },
  getElementById(id) { return id === 'main-content' ? currentContent : null; },
};
globalThis.DOMParser = class {
  parseFromString() {
    return { getElementById: (id) => mode !== 'missing-content' && id === 'main-content' ? nextContent : null };
  }
};

const requests = [];
globalThis.fetch = async (url, options = {}) => {
  requests.push({ url, options });
  if (options.method === 'POST') return { ok: true };
  if (mode === 'rejected') throw new Error('network unavailable');
  if (mode === 'non-ok') return { ok: false };
  return { ok: true, text: async () => '<main id="main-content"></main>' };
};

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(
  /import \{ updateRunningTasksSection, updateRunningWorkflowsSection \} from '\.\/sidebar_sections\.js';/,
  'const updateRunningTasksSection = (tasks) => tasks; const updateRunningWorkflowsSection = () => {};',
);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
controller.connect();

assert(typeof clickListener === 'function', 'start action was not initialized');
await clickListener();

assert(startButton.disabled, 'start action was not disabled while transitioning');
assert(requests.length === 2, 'expected start POST and fragment GET, got ' + requests.length);
assert(requests[0].url === '/api/tasks/task-1/start?token=test', 'start request used the wrong URL');
assert(requests[0].options.method === 'POST', 'start request was not a POST');
assert(requests[1].url === '/tasks/task-1?token=test', 'detail refresh used the wrong URL');
assert(requests[1].options.headers?.['HX-Request'] === 'true', 'detail refresh was not fragment-aware');
if (mode === 'success') {
  assert(replacement === nextContent, 'task detail content was not replaced');
  assert(toasts.length === 0, 'successful refresh showed an error toast');
} else {
  assert(replacement === null, 'failed refresh replaced task detail content');
  assert(startButton.disabled, 'successful start was re-offered after a refresh failure');
  assert(toasts.length === 1, 'failed refresh did not show exactly one toast');
  assert(toasts[0].level === 'error', 'failed refresh toast had the wrong severity');
  assert(toasts[0].message === 'Task started. Refresh the page to see its status.', 'failed refresh toast was unclear');
}
''';
