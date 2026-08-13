import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_scheduling_controller.js');

  test('S03 run action encodes the name and retains it in the success toast', () async {
    await expectNodeHarness(_runJobHarness, [controller.absolute.uri.toString()]);
  });

  test('run action surfaces server and network failures', () async {
    await expectNodeHarness(_runJobFailureHarness, [controller.absolute.uri.toString()]);
  });
}

const _runJobHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

let request;
let resolveFetch;
globalThis.fetch = (url, options) => {
  request = { url, options };
  return new Promise(resolve => { resolveFetch = resolve; });
};
globalThis.Stimulus = { Controller: class {} };
const toasts = [];
globalThis.window = {
  dartclaw: {
    shell: { apiQs: () => '?token=fixture' },
    ui: { showToast: (type, message) => toasts.push({ type, message }) },
  },
};

const source = await readFile(new URL(process.argv[1]), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
const attributes = new Map();
const button = {
  dataset: { jobName: 'Q&A digest' },
  disabled: false,
  setAttribute: (name, value) => attributes.set(name, value),
  removeAttribute: name => attributes.delete(name),
};
const run = controller.runJob({ currentTarget: button });
await Promise.resolve();

assert(request.url === '/api/scheduling/jobs/Q%26A%20digest/run?token=fixture', 'job route was not encoded');
assert(request.options.method === 'POST', 'run action did not POST');
assert(button.disabled === true, 'run action remained enabled while the request was pending');
assert(attributes.get('aria-busy') === 'true', 'run action did not expose its pending state');

resolveFetch({ ok: true, json: async () => ({ name: 'Q&A digest', status: 'started' }) });
await run;

assert(button.disabled === false, 'run action did not re-enable after completion');
assert(!attributes.has('aria-busy'), 'run action retained stale busy state');
assert(toasts.length === 1 && toasts[0].type === 'success', 'success toast missing');
assert(toasts[0].message.includes('Q&A digest') && toasts[0].message.includes('started'), 'toast lost job name');
''';

const _runJobFailureHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
const toasts = [];
globalThis.window = {
  dartclaw: {
    shell: { apiQs: () => '' },
    ui: { showToast: (type, message) => toasts.push({ type, message }) },
  },
};

const source = await readFile(new URL(process.argv[1]), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
const button = {
  dataset: { jobName: 'nightly' },
  disabled: false,
  setAttribute: () => {},
  removeAttribute: () => {},
};

globalThis.fetch = async () => ({
  ok: false,
  json: async () => ({ error: { message: 'Job is already running' } }),
});
await controller.runJob({ currentTarget: button });
assert(toasts.length === 1, 'server failure toast missing');
assert(toasts[0].type === 'error', 'server failure used the wrong toast type');
assert(toasts[0].message === 'Job is already running', 'server failure message was discarded');

globalThis.fetch = async () => { throw new Error('offline'); };
await controller.runJob({ currentTarget: button });
assert(toasts.length === 2, 'network failure toast missing');
assert(toasts[1].type === 'error', 'network failure used the wrong toast type');
assert(toasts[1].message === 'Failed to reach server', 'network fallback changed');
''';
