import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_workflows_controller.js');

  test('workflow controller swaps only server-rendered affected cards', () async {
    await expectNodeHarness(_workflowControllerHarness, [(await controller).absolute.uri.toString()]);
  });

  test('request changes posts the feedback to the endpoint and shows a refusal as a toast', () async {
    await expectNodeHarness(_requestChangesHarness, [(await controller).absolute.uri.toString()]);
  });
}

const _workflowControllerHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function makeStep(index, id, status, loopId = null) {
  const attributes = new Map([
    ['data-step-index', String(index)],
    ['data-step-id', id],
    ['data-step-status', status],
  ]);
  const step = { getAttribute(name) { return attributes.get(name); } };
  step.badge = loopId === null ? null : {
    closest(selector) { return selector === '.pipeline-step' ? step : null; },
  };
  return step;
}

const steps = [makeStep(0, 'first', 'running', 'loop-a'), makeStep(1, 'second', 'pending')];
const detailPage = {
  getAttribute(name) {
    if (name === 'data-run-id') return 'run-1';
    if (name === 'data-run-status') return 'running';
    return null;
  },
};

globalThis.window = {
  location: { pathname: '/workflows/run-1' },
  dartclaw: { ui: {} },
};
globalThis.document = {
  body: { dataset: {}, addEventListener() {} },
  addEventListener() {},
  querySelector(selector) {
    if (selector === '.workflow-detail-page') return detailPage;
    for (const step of steps) {
      if (selector === '.pipeline-step[data-step-index="' + step.getAttribute('data-step-index') + '"]') return step;
      if (selector === '.pipeline-step[data-step-id="' + step.getAttribute('data-step-id') + '"]') return step;
    }
    return null;
  },
  querySelectorAll(selector) {
    if (selector === '.workflow-loop-badge[data-loop-id="loop-a"]') return [steps[0].badge];
    return [];
  },
};
globalThis.Stimulus = { Controller: class {} };
globalThis.EventSource = class {
  constructor() { globalThis.latestEventSource = this; }
  close() {}
};
const ajaxRequests = [];
globalThis.htmx = {
  ajax(method, path, options) { ajaxRequests.push({ method, path, options }); },
  trigger() {},
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

emit({ type: 'workflow_step_completed', stepIndex: 0 });
assert(ajaxRequests.length === 1, 'step completion did not issue exactly one request');
assert(ajaxRequests[0].path === '/workflows/run-1/steps/0/card', 'step completion requested the wrong card');
assert(ajaxRequests[0].options.target === steps[0], 'step completion targeted a sibling card');
assert(ajaxRequests[0].options.swap === 'outerHTML', 'step completion did not replace the card root');

ajaxRequests.length = 0;
emit({ type: 'parallel_group_completed', stepIds: ['first', 'second'], failureCount: 1 });
assert(ajaxRequests.length === 0, 'failed parallel group issued card requests');

emit({ type: 'loop_iteration_completed', loopId: 'loop-a' });
assert(ajaxRequests.length === 1 && ajaxRequests[0].options.target === steps[0], 'loop update missed its owning card');

ajaxRequests.length = 0;
emit({
  type: 'connected',
  run: { status: 'running' },
  steps: [{ index: 0, status: 'running' }, { index: 1, status: 'pending' }],
});
assert(ajaxRequests.length === 0, 'aligned connected snapshot triggered a refresh');

emit({
  type: 'connected',
  run: { status: 'running' },
  steps: [{ index: 0, status: 'completed' }, { index: 1, status: 'pending' }],
});
assert(ajaxRequests.length === 1, 'connected drift did not refresh the detail');
assert(ajaxRequests[0].path === '/workflows/run-1', 'connected drift used the wrong detail URL');
assert(ajaxRequests[0].options.target === '#main-content', 'connected drift used the wrong target');
''';

const _requestChangesHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const toasts = [];
globalThis.window = {
  location: { pathname: '/workflows/run-1' },
  dartclaw: { ui: { showToast(type, message) { toasts.push([type, message]); } } },
};
globalThis.document = {
  body: { dataset: {}, addEventListener() {} },
  addEventListener() {},
  querySelector() { return null; },
  querySelectorAll() { return []; },
};
globalThis.Stimulus = { Controller: class {} };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(
  "import { updateRunningWorkflowsSection } from './sidebar_sections.js';",
  'const updateRunningWorkflowsSection = (items) => items;',
);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();

function makeForm() {
  const button = { disabled: false };
  return {
    button,
    dataset: { runId: 'run-1' },
    elements: { feedback: { value: '  split story 3  ' } },
    querySelector() { return button; },
  };
}

const requests = [];
globalThis.fetch = async (url, init) => {
  requests.push({ url, init });
  return globalThis.nextResponse;
};

const refused = makeForm();
globalThis.nextResponse = {
  ok: false,
  json: async () => ({ error: { code: 'INVALID_TRANSITION', message: 'This approval reached its revision limit' } }),
};
await controller.requestChanges({ preventDefault() {}, currentTarget: refused });
assert(requests[0].url === '/api/workflows/runs/run-1/request-changes', 'wrong endpoint ' + requests[0].url);
assert(requests[0].init.method === 'POST', 'not a POST');
assert(JSON.parse(requests[0].init.body).feedback === '  split story 3  ', 'the field was not posted as typed');
assert(toasts.length === 1 && toasts[0][0] === 'error', 'a refusal did not toast');
assert(toasts[0][1] === 'This approval reached its revision limit', 'the toast lost the refusal text');
assert(refused.button.disabled === false, 'a refused request left the button disabled');

const accepted = makeForm();
globalThis.nextResponse = { ok: true, json: async () => ({}) };
await controller.requestChanges({ preventDefault() {}, currentTarget: accepted });
assert(toasts.length === 1, 'an accepted request toasted');
assert(accepted.button.disabled === true, 'an accepted request let the form be submitted twice');
''';
