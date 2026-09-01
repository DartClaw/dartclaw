import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_scheduling_controller.js');

  test('delete confirmation reveals its full escaped copy in a scrolled mobile table', () async {
    await expectNodeHarness(_deleteConfirmationHarness, [(await controller).absolute.uri.toString()]);
  });
}

const _deleteConfirmationHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function element(tagName) {
  return {
    tagName,
    children: [],
    className: '',
    dataset: {},
    style: {},
    textContent: '',
    append(...children) { this.children.push(...children); },
    appendChild(child) { this.children.push(child); },
    setAttribute(name, value) { this[name] = value; },
  };
}

const tableWrap = { scrollLeft: 185, clientWidth: 351 };
let insertedRow;
const row = {
  cells: [{}, {}, {}],
  nextSibling: null,
  style: {},
  parentNode: {
    insertBefore(next) {
      insertedRow = next;
      insertedRow.previousElementSibling = row;
      insertedRow.remove = () => { insertedRow.removed = true; };
    },
  },
};
const button = {
  dataset: {
    deleteMessage: "Delete 'v23 \"job\" 'quote' <tag> &'?",
    deleteUrl: '/scheduling/jobs/fixture/delete',
  },
  closest(selector) {
    if (selector === 'tr') return row;
    if (selector === '.table-wrap') return tableWrap;
    return null;
  },
};

globalThis.Stimulus = { Controller: class {} };
globalThis.window = { dartclaw: { shell: {}, ui: {} } };
globalThis.document = { createElement: element };
let processed;
globalThis.htmx = { process: node => { processed = node; } };

const source = await readFile(new URL(process.argv[1]), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
const message = button.dataset.deleteMessage;
controller.confirmDelete({ currentTarget: button });

assert(tableWrap.scrollLeft === 0, 'the confirmation kept the table scrolled away from its leading copy');
assert(row.style.display === 'none', 'the source row stayed visible behind its confirmation');
assert(insertedRow?.className === 'delete-confirm-row', 'the confirmation row was not inserted');
const messageNode = insertedRow.children[0].children[0].children[0];
assert(messageNode.textContent === message, 'special-character confirmation copy was altered');
assert(insertedRow.children[0].children[0].style.width === '351px', 'the confirmation exceeded the visible table width');
const confirm = insertedRow.children[0].children[0].children[1];
assert(confirm['hx-post'] === '/scheduling/jobs/fixture/delete', 'the server-provided mutation URL was not used');
assert(processed === confirm, 'the inserted HTMX control was not processed');
const cancel = insertedRow.children[0].children[0].children[2];
cancel.closest = selector => selector === '.delete-confirm-row' ? insertedRow : null;
controller.cancelDelete({ currentTarget: cancel });
assert(row.style.display === '', 'Cancel did not restore the source row');
assert(insertedRow.removed === true, 'Cancel did not remove the confirmation row');
''';
