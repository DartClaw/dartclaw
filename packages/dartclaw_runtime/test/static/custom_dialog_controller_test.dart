import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('custom input dialog settles once, restores focus, and fails closed', () async {
    final shared = await controllerAsset('shared.js');
    await expectNodeHarness(_dialogHarness, [shared.absolute.uri.toString()]);
  });
}

const _dialogHarness = r'''
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName;
    this.children = [];
    this.listeners = new Map();
    this.dataset = {};
    this.isConnected = true;
  }

  appendChild(child) {
    this.children.push(child);
    child.parentNode = this;
    return child;
  }

  append(...children) {
    children.forEach((child) => this.appendChild(child));
  }

  setAttribute(name, value) {
    this[name] = value;
  }

  addEventListener(type, callback) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(callback);
    this.listeners.set(type, listeners);
  }

  dispatch(type, event = {}) {
    for (const callback of this.listeners.get(type) || []) callback({ target: this, ...event });
  }

  showModal() {
    this.open = true;
  }

  close() {
    this.open = false;
    this.dispatch('close');
  }

  remove() {
    this.isConnected = false;
    const index = this.parentNode?.children.indexOf(this) ?? -1;
    if (index >= 0) this.parentNode.children.splice(index, 1);
  }

  focus() {
    this.focused = true;
    document.activeElement = this;
  }

  select() {
    this.selected = true;
  }
}

const body = new FakeElement('body');
const opener = new FakeElement('button');
globalThis.document = {
  body,
  activeElement: opener,
  createElement: (tagName) => new FakeElement(tagName),
  getElementById: () => null,
};
globalThis.window = { dartclaw: {}, location: { search: '' } };

const { confirmDialog, inputDialog } = await import(process.argv[1]);

const inputPromise = inputDialog({
  title: 'Edit queued message',
  body: 'Update this message.',
  inputLabel: 'Message',
  value: 'Original',
  confirmLabel: 'Save',
});
const inputFrame = body.children[0];
const inputBody = inputFrame.children.find((child) => child.className === 'dialog-body');
const input = inputBody.children.find((child) => child.tagName === 'textarea');
assert(inputFrame.className === 'dialog dialog--sm card card-glass', 'input dialog did not use canonical classes');
assert(input.value === 'Original' && input.focused && input.selected, 'input value was not focused and selected');

const overlappingConfirmation = await confirmDialog({ body: 'Should stay closed' });
assert(overlappingConfirmation === false && body.children.length === 1, 'overlapping confirmation did not fail closed');

let prevented = false;
input.value = 'Replacement';
input.dispatch('keydown', {
  key: 'Enter',
  ctrlKey: true,
  metaKey: false,
  isComposing: false,
  preventDefault() { prevented = true; },
});
assert(await inputPromise === 'Replacement', 'keyboard acceptance lost the edited value');
assert(prevented && opener.focused && body.children.length === 0, 'keyboard acceptance did not close and restore focus');

const cancelledPromise = inputDialog({ title: 'Edit and continue', value: 'Original' });
const cancelledFrame = body.children[0];
cancelledFrame.close();
assert(await cancelledPromise === null, 'Escape-style close did not fail closed');

const confirmedPromise = confirmDialog({ title: 'Retry?', body: 'Effects may repeat.', confirmLabel: 'Retry' });
const confirmedFrame = body.children[0];
const confirmFooter = confirmedFrame.children.find((child) => child.className === 'dialog-footer');
confirmFooter.children[0].children[1].dispatch('click');
assert(await confirmedPromise === true, 'confirmation did not settle true');
''';
