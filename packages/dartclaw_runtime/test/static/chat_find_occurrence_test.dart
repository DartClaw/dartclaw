import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('find splits a text node into one mark per occurrence', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_findHarness, [controller.absolute.uri.toString()]);
  });
}

/// A reader looking for a word expects every place it appears. Counting
/// *messages* reports "1 of 1" for a word that occurs three times on screen and
/// leaves the other two unreachable, so the unit is the occurrence.
///
/// This pins the splitting arithmetic — the part that silently drops or
/// duplicates text when it is wrong. The tree walk, the `pre` skip and the
/// active-mark stepping need a real document and are verified in the browser.
const _findHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// The smallest document `markTextNode` actually touches.
class FakeNode {
  constructor(kind, data) { this.kind = kind; this.data = data ?? ''; this.children = []; this.className = ''; }
  get textContent() {
    return this.kind === 'text' ? this.data : this.children.map((child) => child.textContent).join('');
  }
  set textContent(value) {
    if (this.kind === 'text') { this.data = value; return; }
    this.children = [new FakeNode('text', value)];
  }
  appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
  replaceChild(next, previous) {
    const at = this.children.indexOf(previous);
    this.children.splice(at, 1, ...(next.kind === 'fragment' ? next.children : [next]));
    return previous;
  }
}
globalThis.document = {
  createTextNode: (data) => new FakeNode('text', data),
  createElement: (tag) => new FakeNode(tag),
  createDocumentFragment: () => new FakeNode('fragment'),
};
globalThis.Stimulus = { Controller: class {} };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const beginSessionDraftMutation = () => {};
const endSessionDraftMutation = () => {};
const escapeHtml = (value) => String(value);
const isAtBottom = () => false;
const readHtmxErrorMessage = () => '';
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showBanner = () => {};
const showToast = () => {};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();

function split(text, needle) {
  const parent = new FakeNode('p');
  const node = parent.appendChild(new FakeNode('text', text));
  const marks = controller.markTextNode(node, needle);
  return { marks, parent };
}

// Three occurrences in one node are three stops, and the sentence survives.
const many = split('echo one, echo two, then echo three', 'echo');
assert(many.marks.length === 3, 'a node with three occurrences produced ' + many.marks.length + ' marks');
assert(many.parent.textContent === 'echo one, echo two, then echo three', 'splitting lost or duplicated text');
assert(many.marks.every((mark) => mark.className === 'find-hit'), 'a mark was not a find hit');
assert(many.marks.every((mark) => mark.textContent === 'echo'), 'a mark covered more than its occurrence');

// The needle is lowercased by the caller; matching must ignore case while the
// mark keeps the text exactly as written.
const cased = split('Echo and ECHO and echo', 'echo');
assert(cased.marks.length === 3, 'case-different occurrences were missed');
assert(cased.marks[0].textContent === 'Echo' && cased.marks[1].textContent === 'ECHO', 'a mark rewrote its text');
assert(cased.parent.textContent === 'Echo and ECHO and echo', 'case-insensitive marking altered the text');

// Adjacent occurrences must not overlap or swallow each other.
const adjacent = split('aaaa', 'aa');
assert(adjacent.marks.length === 2, 'adjacent occurrences collapsed to ' + adjacent.marks.length);
assert(adjacent.parent.textContent === 'aaaa', 'adjacent marking altered the text');

// Occurrences at both edges keep no empty text nodes and lose no characters.
const edges = split('echo middle echo', 'echo');
assert(edges.marks.length === 2, 'edge occurrences were missed');
assert(edges.parent.textContent === 'echo middle echo', 'edge marking altered the text');

// A node with no occurrence is left alone entirely.
const none = split('nothing here', 'echo');
assert(none.marks.length === 0, 'a non-matching node produced marks');
assert(none.parent.children.length === 1 && none.parent.children[0].kind === 'text', 'a non-matching node was rebuilt');
''';
