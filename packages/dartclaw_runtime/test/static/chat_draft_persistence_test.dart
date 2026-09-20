import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final controller = controllerAsset('dc_chat_controller.js');

  test('a draft typed before the session exists is stored under the provisional key', () async {
    // A New Chat composer has no session id until the first send, so the only
    // place its draft can live is a key not derived from one. Without that key
    // everything typed before the first send is unrecoverable after a reload.
    await expectNodeHarness(_provisionalKeyHarness, [(await controller).absolute.uri.toString()]);
  });

  test('a provisional draft moves to the session key and the provisional record is deleted', () async {
    // The session id arrives after the draft was written, so the record has to
    // follow it. A left-behind provisional record would also be picked up by
    // the next New Chat composer as somebody else's half-typed message.
    await expectNodeHarness(_transferHarness, [(await controller).absolute.uri.toString()]);
  });

  test('a stored draft is restored into the composer on load', () async {
    // Persisting a draft is only half the promise: the reader has to find the
    // text, its references and its revision identity back in the composer,
    // untouched, or the storage round-trip bought nothing.
    await expectNodeHarness(_restoreHarness, [(await controller).absolute.uri.toString()]);
  });

  test('a transferred draft is not re-transferred and never clobbers a session draft', () async {
    // The transfer runs on every load of the session, and a provisional record
    // outlives the conversation that produced it. Replaying it would overwrite
    // whatever the reader has typed since with a stale message.
    await expectNodeHarness(_noSecondTransferHarness, [(await controller).absolute.uri.toString()]);
  });
}

/// Shared prelude: loads the controller with its `shared.js` imports stubbed,
/// and stands in for IndexedDB with a `Map`-backed database whose requests and
/// transactions settle on microtasks in the order the real API would.
const _prelude = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const flush = async () => {
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
};

class FakeDraftDb {
  constructor(records) {
    this.records = records;
  }

  transaction(name, mode) {
    assert(name === 'drafts', 'unexpected object store: ' + name);
    const records = this.records;
    const transaction = { error: null, oncomplete: null, onabort: null };
    let pending = 0;
    const queue = (run) => {
      const request = { result: undefined, error: null, onsuccess: null, onerror: null };
      pending += 1;
      Promise.resolve().then(() => {
        try {
          request.result = run();
          if (request.onsuccess) request.onsuccess();
        } catch (error) {
          request.error = error;
          if (request.onerror) request.onerror();
        }
        pending -= 1;
        if (pending === 0 && transaction.oncomplete) transaction.oncomplete();
      });
      return request;
    };
    const store = {
      get: (key) => queue(() => records.get(key)),
      put: (value) => queue(() => {
        assert(mode === 'readwrite', 'write attempted in a ' + mode + ' transaction');
        records.set(value.key, value);
        return value.key;
      }),
      delete: (key) => queue(() => {
        assert(mode === 'readwrite', 'delete attempted in a ' + mode + ' transaction');
        records.delete(key);
      }),
    };
    transaction.objectStore = (storeName) => {
      assert(storeName === 'drafts', 'unexpected object store: ' + storeName);
      return store;
    };
    return transaction;
  }
}

globalThis.Stimulus = { Controller: class {} };
// Node ships a real BroadcastChannel whose MessagePort keeps the event loop
// alive forever, so the harness would never exit on its own.
globalThis.broadcasts = [];
globalThis.BroadcastChannel = class {
  constructor(name) { this.name = name; this.onmessage = null; }
  postMessage(message) { globalThis.broadcasts.push(message); }
  close() {}
};
globalThis.storage = new Map([['dartclaw.instance-id', 'inst']]);
globalThis.localStorage = {
  getItem: (key) => (globalThis.storage.has(key) ? globalThis.storage.get(key) : null),
  setItem: (key, value) => globalThis.storage.set(key, String(value)),
  removeItem: (key) => globalThis.storage.delete(key),
};
globalThis.document = { body: { classList: { add() {}, remove() {} } }, getElementById: () => null };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const beginSessionDraftMutation = () => {};
const confirmDialog = async () => true;
const conversationDraftSessionIds = async () => [];
const endSessionDraftMutation = () => {};
const escapeHtml = (value) => String(value);
const inputDialog = async () => null;
const isAtBottom = () => false;
const openConversationDraftDb = () => globalThis.openDraftDb();
const readHtmxErrorMessage = () => '';
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showBanner = () => {};
const showToast = () => {};
`);
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

function makeComposer({ sessionId, records }) {
  const textarea = { value: '', selectionStart: 0, scrollHeight: 40, style: {}, focus() {}, setSelectionRange() {} };
  const saveStatus = { textContent: '', classList: { toggle() {} } };
  const attachmentsInput = { value: '' };
  const referencesInput = { value: '' };
  const contextTray = { hidden: true, innerHTML: '' };
  const element = {
    dataset: sessionId ? { sessionId } : {},
    querySelector(selector) {
      if (selector === '#message-input') return textarea;
      if (selector === '[data-dc-chat-target="saveStatus"]') return saveStatus;
      if (selector === '[data-dc-chat-target="attachmentsInput"]') return attachmentsInput;
      if (selector === '[data-dc-chat-target="referencesInput"]') return referencesInput;
      if (selector === '[data-dc-chat-target="contextTray"]') return contextTray;
      return null;
    },
  };
  const controller = new module.default();
  controller.element = element;
  controller.attachments = [];
  controller.references = [];
  controller.streaming = false;
  globalThis.openDraftDb = () => Promise.resolve(new FakeDraftDb(records));
  return { controller, textarea, saveStatus };
}
''';

const _provisionalKeyHarness =
    _prelude +
    r'''
const records = new Map();
const { controller, textarea } = makeComposer({ sessionId: null, records });
controller.initializeDraftStorage();
await flush();

assert(controller.provisionalDraftKey === 'inst:provisional',
  'the provisional key was not derived from the device instance id: ' + controller.provisionalDraftKey);
assert(controller.draftKey === 'inst:provisional',
  'a sessionless composer did not write under the provisional key: ' + controller.draftKey);

textarea.value = 'half a thought, before the first send';
controller.markDraftChanged();
await controller.saveDraftNow();
await flush();

assert(records.size === 1, 'a sessionless save wrote ' + records.size + ' records');
const stored = records.get('inst:provisional');
assert(stored, 'nothing was stored under the provisional key');
assert(stored.text === 'half a thought, before the first send', 'the typed text was not stored: ' + stored.text);
assert(stored.submissionId && stored.revisionId, 'the stored draft carried no submission or revision identity');
''';

const _transferHarness =
    _prelude +
    r'''
const records = new Map([['inst:provisional', {
  key: 'inst:provisional',
  text: 'typed before the session existed',
  references: [],
  attachments: [],
  submissionId: 'sub-1',
  revisionId: 'rev-1',
  updatedAt: 1,
}]]);
const { controller, textarea } = makeComposer({ sessionId: 'session-9', records });
controller.initializeDraftStorage();
await flush();

assert(controller.draftKey === 'inst:session-9', 'the composer did not key off the session: ' + controller.draftKey);
const moved = records.get('inst:session-9');
assert(moved, 'the provisional draft never reached the session key');
assert(moved.text === 'typed before the session existed', 'the transferred text changed: ' + moved.text);
assert(moved.key === 'inst:session-9', 'the transferred record kept its old key: ' + moved.key);
assert(moved.submissionId === 'sub-1', 'the transfer discarded the submission identity');
assert(!records.has('inst:provisional'), 'the provisional record survived the transfer');
assert(textarea.value === 'typed before the session existed',
  'the transferred draft was not applied to the composer: ' + textarea.value);
''';

const _restoreHarness =
    _prelude +
    r'''
const records = new Map([['inst:session-9', {
  key: 'inst:session-9',
  text: 'the message this reader left unsent',
  references: [{ type: 'project', id: 'p1', label: 'Project One', state: 'resolved' }],
  attachments: [],
  submissionId: 'sub-7',
  revisionId: 'rev-7',
  updatedAt: 2,
}]]);
const { controller, textarea, saveStatus } = makeComposer({ sessionId: 'session-9', records });
controller.initializeDraftStorage();
await flush();

assert(textarea.value === 'the message this reader left unsent', 'the stored text was not restored: ' + textarea.value);
assert(controller.references.length === 1 && controller.references[0].id === 'p1',
  'the stored references were not restored');
assert(controller.draftSubmissionId === 'sub-7', 'the restored draft was given a new submission id');
assert(controller.draftRevisionId === 'rev-7', 'the restored draft was given a new revision id');
assert(controller.draftTouched === false, 'a restored draft counted as an unsaved edit');
assert(saveStatus.textContent === 'Draft restored', 'the restore was not reported: ' + saveStatus.textContent);
''';

const _noSecondTransferHarness =
    _prelude +
    r'''
// A transfer that already happened must not run again over later edits.
const records = new Map([['inst:provisional', {
  key: 'inst:provisional',
  text: 'the original provisional draft',
  references: [],
  attachments: [],
  submissionId: 'sub-1',
  revisionId: 'rev-1',
  updatedAt: 1,
}]]);
const first = makeComposer({ sessionId: 'session-9', records });
first.controller.initializeDraftStorage();
await flush();
assert(!records.has('inst:provisional'), 'the provisional record survived the first transfer');

first.textarea.value = 'edited after the transfer';
first.controller.markDraftChanged();
await first.controller.saveDraftNow();
await flush();

const replayed = await first.controller.transferProvisionalDraft();
await flush();
assert(replayed === null, 'a second transfer reported moving a record that was already gone');
assert(records.get('inst:session-9').text === 'edited after the transfer',
  'a replayed transfer overwrote the later edit: ' + records.get('inst:session-9').text);

// A stale provisional draft must lose to a draft already held for the session.
const both = new Map([
  ['inst:session-9', {
    key: 'inst:session-9',
    text: 'the draft belonging to this session',
    references: [],
    attachments: [],
    submissionId: 'sub-2',
    revisionId: 'rev-2',
    updatedAt: 5,
  }],
  ['inst:provisional', {
    key: 'inst:provisional',
    text: 'a stale provisional draft from another conversation',
    references: [],
    attachments: [],
    submissionId: 'sub-3',
    revisionId: 'rev-3',
    updatedAt: 9,
  }],
]);
const second = makeComposer({ sessionId: 'session-9', records: both });
second.controller.initializeDraftStorage();
await flush();

assert(second.textarea.value === 'the draft belonging to this session',
  'the stale provisional draft was applied over the session draft: ' + second.textarea.value);
assert(both.get('inst:session-9').text === 'the draft belonging to this session',
  'the session record was clobbered by the provisional one');
assert(both.get('inst:provisional').text === 'a stale provisional draft from another conversation',
  'the untransferred provisional record was modified');
''';
