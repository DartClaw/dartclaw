import 'dart:io';

import 'package:test/test.dart';

void main() {
  final controller = File('packages/dartclaw_server/lib/src/static/controllers/dc_workflows_controller.js').existsSync()
      ? File('packages/dartclaw_server/lib/src/static/controllers/dc_workflows_controller.js')
      : File('lib/src/static/controllers/dc_workflows_controller.js');

  test('workflow controller reconciles detail errors and live step state', () async {
    ProcessResult result;
    try {
      result = await Process.run('node', [
        '--input-type=module',
        '--eval',
        _workflowControllerHarness,
        controller.absolute.uri.toString(),
      ]);
    } on ProcessException {
      markTestSkipped('Node is unavailable');
      return;
    }

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });
}

const _workflowControllerHarness = r'''
import { readFile } from 'node:fs/promises';

class WorkflowHarnessClassList {
  constructor(...names) { this.names = new Set(names); }
  add(...names) { names.forEach((name) => this.names.add(name)); }
  remove(...names) { names.forEach((name) => this.names.delete(name)); }
  contains(name) { return this.names.has(name); }
  toggle(name, force) {
    const enabled = force === undefined ? !this.names.has(name) : force;
    if (enabled) this.names.add(name); else this.names.delete(name);
    return enabled;
  }
  [Symbol.iterator]() { return this.names[Symbol.iterator](); }
}

function makeStep(index, id, status = 'pending') {
  const icon = {
    classList: new WorkflowHarnessClassList('workflow-step-icon', 'workflow-step-icon--' + status),
    textContent: '○',
  };
  const attributes = new Map([
    ['data-step-index', String(index)],
    ['data-step-id', id],
    ['data-step-status', status],
  ]);
  return {
    icon,
    classList: new WorkflowHarnessClassList(),
    querySelector(selector) { return selector === '.workflow-step-icon' ? icon : null; },
    getAttribute(name) { return attributes.get(name); },
    setAttribute(name, value) { attributes.set(name, String(value)); },
    scrollIntoView() {},
  };
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const steps = [makeStep(0, 'first'), makeStep(1, 'second')];
const bySelector = new Map();
function register(step, index, id) {
  bySelector.set('.workflow-step-card[data-step-index="' + index + '"]', step);
  bySelector.set('.workflow-step-card[data-step-id="' + id + '"]', step);
}
register(steps[0], 0, 'first');
register(steps[1], 1, 'second');

const detailPage = {
  getAttribute(name) {
    if (name === 'data-run-id') return 'run-1';
    if (name === 'data-run-status') return 'running';
    return null;
  },
};
const fill = { style: {} };
const label = { textContent: '' };
const percentage = { textContent: '' };
const progress = {
  querySelector(selector) {
    if (selector === '.meter-fill') return fill;
    if (selector === '.workflow-progress-label') return label;
    if (selector === '.workflow-progress-pct') return percentage;
    return null;
  },
};

globalThis.window = {
  location: { pathname: '/workflows/run-1', href: 'http://localhost/workflows/run-1' },
  dartclaw: { ui: { escapeHtml: (value) => String(value) } },
};
globalThis.document = {
  body: { dataset: {}, addEventListener() {} },
  addEventListener() {},
  getElementById() { return null; },
  querySelector(selector) {
    if (selector === '.workflow-detail-page') return detailPage;
    if (selector === '.workflow-progress-section') return progress;
    return bySelector.get(selector) || null;
  },
  querySelectorAll(selector) {
    if (selector === '.workflow-step-card[data-step-status="completed"]') {
      return steps.filter((step) => step.getAttribute('data-step-status') === 'completed');
    }
    return [];
  },
};
globalThis.Stimulus = { Controller: class {} };
globalThis.EventSource = class {
  constructor() { globalThis.latestEventSource = this; }
  close() {}
};
const triggers = [];
const ajaxRequests = [];
globalThis.htmx = {
  ajax(method, path, options) { ajaxRequests.push([method, path, options]); },
  trigger(source, name) { triggers.push([source, name]); },
};

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(
  "import { updateRunningWorkflowsSection } from './sidebar_sections.js';",
  'const updateRunningWorkflowsSection = (items) => items;',
);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
controller.connect();

function emit(data) {
  globalThis.latestEventSource.onmessage({ data: JSON.stringify(data) });
}

emit({ type: 'workflow_step_completed', stepIndex: 0, outcome: 'succeeded', success: true, totalSteps: 2 });
assert(steps[0].getAttribute('data-step-status') === 'completed', 'completed status was not applied');
assert(steps[0].icon.textContent === '✓', 'completed glyph was not applied');
assert(steps[0].icon.classList.contains('workflow-step-icon--completed'), 'completed class was not applied');
assert(steps[1].getAttribute('data-step-status') === 'pending', 'completion guessed the next step state');

for (const [taskStatus, displayStatus, glyph] of [
  ['queued', 'queued', '○'],
  ['running', 'running', '•'],
  ['interrupted', 'interrupted', '!'],
  ['review', 'review', '○'],
  ['accepted', 'completed', '✓'],
  ['cancelled', 'cancelled', '○'],
  ['rejected', 'failed', '✗'],
]) {
  emit({ type: 'task_status_changed', stepIndex: 1, newStatus: taskStatus });
  assert(steps[1].getAttribute('data-step-status') === displayStatus, taskStatus + ' status was not mapped');
  assert(steps[1].icon.textContent === glyph, taskStatus + ' glyph was not mapped');
}

steps.push(makeStep(2, 'parallel-a', 'running'), makeStep(3, 'parallel-b', 'running'));
register(steps[2], 2, 'parallel-a');
register(steps[3], 3, 'parallel-b');
emit({
  type: 'workflow_step_completed',
  stepIndex: 2,
  outcome: 'needsInput',
  success: false,
  totalSteps: 4,
});
emit({ type: 'workflow_step_completed', stepIndex: 3, outcome: 'succeeded', success: true, totalSteps: 4 });
emit({
  type: 'parallel_group_completed',
  stepIds: ['parallel-a', 'parallel-b'],
  successCount: 1,
  failureCount: 1,
});
assert(steps[2].getAttribute('data-step-status') === 'interrupted', 'partial failure overwrote member truth');
assert(steps[2].icon.textContent === '!', 'partial failure overwrote the interrupted glyph');
assert(steps[3].getAttribute('data-step-status') === 'completed', 'successful parallel member was not completed');
assert(steps[3].icon.textContent === '✓', 'successful parallel glyph was not applied');

const loading = { hidden: false };
const error = { hidden: true };
const lazySource = {
  matches(selector) { return selector === '.workflow-step-detail-loading'; },
  querySelector(selector) {
    if (selector === '[data-step-detail-loading]') return loading;
    if (selector === '[data-step-detail-error]') return error;
    return null;
  },
};
const retryButton = { closest() { return lazySource; } };
controller.showStepDetailError({ detail: { elt: lazySource } });
assert(loading.hidden && !error.hidden, 'HTMX failure did not replace the skeleton');
controller.retryStepDetail({ currentTarget: retryButton });
assert(!loading.hidden && error.hidden, 'retry did not restore the loading state');
assert(triggers.length === 1 && triggers[0][1] === 'workflow-step-detail-retry', 'retry did not request the fragment');

emit({
  type: 'connected',
  run: { status: 'running' },
  steps: [
    { index: 0, status: 'completed' },
    { index: 1, status: 'failed' },
    { index: 2, status: 'interrupted' },
    { index: 3, status: 'completed' },
  ],
});
assert(ajaxRequests.length === 0, 'aligned connected snapshot triggered a refresh');
emit({
  type: 'connected',
  run: { status: 'running' },
  steps: [
    { index: 0, status: 'completed' },
    { index: 1, status: 'pending' },
    { index: 2, status: 'interrupted' },
    { index: 3, status: 'completed' },
  ],
});
assert(ajaxRequests.length === 1, 'connected step drift did not refresh the authoritative detail');
''';
