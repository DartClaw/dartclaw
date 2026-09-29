import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('the shell reaches chat-owned surfaces through the four pinned actions', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_chatActionHarness, [controller.absolute.uri.toString()]);
  });
}

/// The topbar overflow menu and the command palette are outside this
/// controller's element and hold no reference to it, so `dartclaw:chat-action`
/// is the whole contract between them. A renamed action fails silently in the
/// browser — the handler simply ignores what it does not recognise — so the
/// four strings are pinned here rather than left to a source grep.
const _chatActionHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.document = { body: { classList: { add() {}, remove() {} } }, getElementById: () => null };

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
const called = [];
controller.openFind = () => called.push('openFind');
controller.openTemporaryExport = () => called.push('openTemporaryExport');
controller.openTemporaryCreate = () => called.push('openTemporaryCreate');
controller.openTemporaryEnd = () => called.push('openTemporaryEnd');

function dispatch(action) {
  let stopped = false;
  controller.handleChatAction({ detail: { action }, stopPropagation() { stopped = true; } });
  return stopped;
}

assert(dispatch('find') && called.at(-1) === 'openFind', 'find did not open the find bar');
assert(dispatch('export') && called.at(-1) === 'openTemporaryExport', 'export did not open the export dialog');
assert(dispatch('temporary-create') && called.at(-1) === 'openTemporaryCreate', 'temporary-create did not open its dialog');
assert(dispatch('temporary-end') && called.at(-1) === 'openTemporaryEnd', 'temporary-end did not open its dialog');
assert(called.length === 4, 'a pinned action ran more than one handler');

// An action this controller does not own belongs to whoever dispatched it, so
// it is left to bubble rather than swallowed.
assert(!dispatch('temporary-export'), 'the retired action name was still accepted');
assert(!dispatch(undefined), 'a detail-less event was consumed');
assert(!dispatch('reset'), 'an unowned action was consumed');
assert(called.length === 4, 'an unrecognised action ran a handler');
''';
