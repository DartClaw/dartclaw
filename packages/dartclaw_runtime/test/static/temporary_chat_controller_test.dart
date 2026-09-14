import 'dart:io';

import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  test('temporary drafts use only module memory and warn before page unload', () {
    final source = File('packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js')
        .readAsStringSync();
    expect(source, contains('const temporaryDrafts = new Map();'));
    expect(source, contains("this.element.dataset.retention === 'process'"));
    expect(source, contains("window.addEventListener('beforeunload', this.handleTemporaryBeforeUnload)"));
    expect(source, contains("window.addEventListener('pagehide', this.handleTemporaryPageHide)"));
    expect(source, contains('handleTemporaryPageHide()'));
    final temporaryBranch = source.substring(
      source.indexOf('if (this.isTemporary) {', source.indexOf('initializeDraftStorage')),
    );
    expect(temporaryBranch, contains('temporaryDrafts.get'));
    expect(temporaryBranch.indexOf('temporaryDrafts.get'), lessThan(temporaryBranch.indexOf('localStorage.getItem')));
    expect(source, contains('temporaryDrafts.delete(this.sessionId)'));
    expect(source, contains('handleTemporaryDialogKeydown'));
    expect(source, contains(r'''body: JSON.stringify({ retention: 'process', disclosureAccepted: true })'''));
    expect(source, contains(r'''body: JSON.stringify({ confirmed: true, durableCopyAccepted: true })'''));
    final template = File('packages/dartclaw_runtime/lib/src/templates/chat.html').readAsStringSync();
    expect(template, contains('data-action="dc-chat#openTemporaryEnd"'));
    expect(template, contains('id="temporary-end-dialog"'));
    expect(template, contains('data-action="dc-chat#endTemporary"'));
    expect(template, contains('data-action="dc-chat#openTemporaryExport"'));
    expect(
      template,
      contains(
        r'''<button tl:unless="${isTemporary}" type="button" class="btn btn-ghost" data-action="dc-chat#openTemporaryExport">Export</button>''',
      ),
    );
    expect(template, contains(r'hx-history=${historyDisabled}'));
    final web = File('packages/dartclaw_runtime/lib/src/web/web_routes.dart').readAsStringSync();
    expect(web, contains("'cache-control': 'no-store'"));
    expect(web, contains('hx-history="false"'));
  });

  test('temporary actions retain their button across native event dispatch and awaits', () async {
    final controller = await controllerAsset('dc_chat_controller.js');
    await expectNodeHarness(_temporaryActionHarness, [controller.absolute.uri.toString()]);
  });
}

const _temporaryActionHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

globalThis.Stimulus = { Controller: class {} };
globalThis.window = { location: { assign() {} } };
let banner;
let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const beginSessionDraftMutation = () => {};
const endSessionDraftMutation = () => {};
const escapeHtml = (value) => String(value);
const isAtBottom = () => false;
const readHtmxErrorMessage = () => '';
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showBanner = (message, level) => { globalThis.fixtureBanner = { message, level }; };
const showToast = () => {};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
controller.element = { dataset: { sessionId: 'temporary-1' } };

function deferred() {
  let resolve;
  return { promise: new Promise((accept) => { resolve = accept; }), resolve };
}

const createButton = new EventTarget();
createButton.disabled = false;
const createResponse = deferred();
globalThis.fetch = () => createResponse.promise;
let createPending;
createButton.addEventListener('click', (event) => { createPending = controller.createTemporary(event); });
createButton.dispatchEvent(new Event('click'));
assert(createButton.disabled, 'create button was not disabled synchronously');
createResponse.resolve({ ok: false, json: async () => ({ error: { message: 'capability unavailable' } }) });
await createPending;
assert(createButton.disabled === false, 'create failure did not re-enable the dispatched button');
assert(globalThis.fixtureBanner?.message === 'capability unavailable', 'create failure was not disclosed');

let dialogClosed = false;
const exportDialog = { close() { dialogClosed = true; } };
const exportButton = new EventTarget();
exportButton.disabled = false;
exportButton.closest = (selector) => selector === 'dialog' ? exportDialog : null;
const exportResponse = deferred();
globalThis.fetch = () => exportResponse.promise;
let clicked = false;
globalThis.document = { createElement: () => ({ click() { clicked = true; } }) };
globalThis.URL.createObjectURL = () => 'blob:fixture';
globalThis.URL.revokeObjectURL = () => {};
let exportPending;
exportButton.addEventListener('click', (event) => { exportPending = controller.exportTemporary(event); });
exportButton.dispatchEvent(new Event('click'));
assert(exportButton.disabled, 'export button was not disabled synchronously');
exportResponse.resolve({ ok: true, blob: async () => new Blob(['export']) });
await exportPending;
assert(clicked, 'export download was not triggered');
assert(dialogClosed, 'export success did not close the originating dialog');
assert(exportButton.disabled === false, 'export completion did not re-enable the dispatched button');
''';
