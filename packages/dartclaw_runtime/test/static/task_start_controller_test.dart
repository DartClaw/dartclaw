import 'dart:io';

import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('task action requests and rendering are declared outside the controller', () async {
    final source = await File((await controllerAsset('dc_tasks_controller.js')).path).readAsString();

    expect(source, isNot(contains('/api/tasks/')));
    expect(source, contains("const tasksApiPath = '/api/tasks';"));
    expect(source, isNot(contains("'/api/' + 'tasks")));
    expect(source, isNot(contains('JSON.stringify')));
    expect(source, isNot(contains('window.location.href =')));
    expect(source, isNot(contains('refreshTaskDetailContent')));
    expect(source, isNot(contains('initTaskStartActions')));
    expect(source, isNot(contains('initTaskCancelActions')));
    expect(source, isNot(contains('initTaskReviewActions')));
  });

  test('a replacement task controller keeps the live refresh lifecycle owned by the newest instance', () async {
    final controller = await controllerAsset('dc_tasks_controller.js');
    await expectNodeHarness(_controllerReplacementHarness, [controller.path]);
  });
}

const _controllerReplacementHarness = r'''
import { pathToFileURL } from 'node:url';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.window = globalThis;
globalThis.Stimulus = { Controller: class {} };
globalThis.dartclaw = { ui: { initCustomSelects() {} }, shell: {} };

let eventSourceClosed = 0;
globalThis.EventSource = class {
  close() { eventSourceClosed += 1; }
};

let intervalCleared = 0;
globalThis.setInterval = () => 1;
globalThis.clearInterval = () => { intervalCleared += 1; };

const detailPage = {
  querySelector() { return { textContent: 'Queued' }; },
};
globalThis.document = {
  querySelector(selector) {
    if (selector === '[data-tasks-enabled]') return {};
    if (selector === '.task-detail-page') return detailPage;
    return null;
  },
  querySelectorAll() { return []; },
  getElementById() { return null; },
};

const moduleUrl = pathToFileURL(process.argv[1]);
moduleUrl.searchParams.set('replacement-test', String(Date.now()));
const { default: TasksController } = await import(moduleUrl.href);
const element = { matches() { return false; } };
const previous = new TasksController();
previous.element = element;
previous.connect();

// Stimulus may connect the replacement before disconnecting the swapped-out
// controller. The older disconnect must not tear down the shared live state.
const replacement = new TasksController();
replacement.element = element;
replacement.connect();
previous.disconnect();

assert(eventSourceClosed === 0, 'older controller closed the replacement event stream');
assert(intervalCleared === 0, 'older controller cleared the replacement detail refresh');

replacement.disconnect();
assert(eventSourceClosed === 1, 'current controller did not close its event stream');
assert(intervalCleared === 1, 'current controller did not clear its detail refresh');
''';
