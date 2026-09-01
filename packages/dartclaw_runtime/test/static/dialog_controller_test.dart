import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_dialog_controller.js');

  test('a swapped-in dialog is shown modally and closes on its close controls', () async {
    await expectNodeHarness(_dialogLifecycleHarness, [(await controller).absolute.uri.toString()]);
  });
}

const _dialogLifecycleHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

let showModalCalls = 0;
let closeCalls = 0;
const listeners = {};

const dialog = {
  open: false,
  showModal() { showModalCalls += 1; this.open = true; },
  close() { closeCalls += 1; this.open = false; },
  addEventListener(type, handler) { listeners[type] = handler; },
  removeEventListener(type) { delete listeners[type]; },
};

globalThis.Stimulus = { Controller: class {} };

const source = await readFile(new URL(process.argv[1]), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
controller.element = dialog;

controller.connect();
assert(showModalCalls === 1, 'the swapped-in dialog was not shown as a modal');
assert(typeof listeners.click === 'function', 'the dialog is not listening for its close controls');

// A click that is not on a close control leaves the dialog open.
listeners.click({ target: { closest: () => null } });
assert(closeCalls === 0, 'an unrelated click closed the dialog');

listeners.click({ target: { closest: (selector) => (selector === '[data-dialog-close]' ? {} : null) } });
assert(closeCalls === 1, 'the close control did not close the dialog');

// showModal() throws on a dialog that is already open, so reconnecting to one must not call it.
dialog.open = true;
controller.connect();
assert(showModalCalls === 1, 'showModal was called on an already-open dialog');

controller.disconnect();
assert(listeners.click === undefined, 'the click listener outlived the dialog');
''';
