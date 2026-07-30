import 'dart:io';

import 'package:test/test.dart';

/// The guard audit refreshes every 30s by replacing its whole container, so the
/// reader's expanded row only survives if the controller re-finds it by the
/// server's presentation key. Driven by synthetic `htmx:beforeSwap` /
/// `htmx:afterSwap` payloads – no clock, no network, no htmx.
void main() {
  final controller = File('packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js').existsSync()
      ? File('packages/dartclaw_server/lib/src/static/controllers/dc_shell_controller.js')
      : File('lib/src/static/controllers/dc_shell_controller.js');

  test('audit disclosure survives a poll, and only for the same row identity', () async {
    ProcessResult result;
    try {
      result = await Process.run('node', [
        '--input-type=module',
        '--eval',
        _auditDisclosureHarness,
        controller.absolute.uri.toString(),
      ]);
    } on ProcessException {
      markTestSkipped('Node is unavailable');
      return;
    }

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });
}

const _auditDisclosureHarness = r'''
import { readFile } from 'node:fs/promises';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

class ClassList {
  constructor(...names) { this.names = new Set(names); }
  add(...names) { names.forEach((n) => this.names.add(n)); }
  remove(...names) { names.forEach((n) => this.names.delete(n)); }
  contains(name) { return this.names.has(name); }
  toggle(name, force) {
    const on = force === undefined ? !this.names.has(name) : force;
    if (on) this.names.add(name); else this.names.delete(name);
    return on;
  }
}

// One audit page: a toggle button per row, each pointing at its own detail row.
function makeTable(keys) {
  const toggles = [];
  const detailRows = new Map();
  const rows = [];

  for (const key of keys) {
    const detailId = 'audit-detail-' + key;
    const detailRow = { id: detailId, hidden: true, classList: new ClassList('audit-detail-row') };
    detailRows.set(detailId, detailRow);

    const row = { classList: new ClassList('audit-row') };
    const attrs = new Map([['aria-expanded', 'false'], ['aria-controls', detailId]]);
    const toggle = {
      dataset: { auditKey: key },
      classList: new ClassList('audit-row-toggle'),
      getAttribute: (n) => (attrs.has(n) ? attrs.get(n) : null),
      setAttribute: (n, v) => attrs.set(n, String(v)),
      closest: (sel) => (sel === '.audit-row' ? row : null),
    };
    row.toggle = toggle;
    toggles.push(toggle);
    rows.push(row);
  }

  const container = {
    id: 'audit-table-container',
    querySelector(selector) {
      if (selector === '.audit-row-toggle[aria-expanded="true"]') {
        return toggles.find((t) => t.getAttribute('aria-expanded') === 'true') || null;
      }
      return null;
    },
  };

  return { toggles, detailRows, container };
}

let table = makeTable(['alpha', 'beta', 'gamma']);

globalThis.CSS = { escape: (value) => value };
globalThis.window = { location: { pathname: '/health-dashboard' }, addEventListener() {} };
globalThis.document = {
  body: { dataset: {}, addEventListener() {}, removeEventListener() {} },
  addEventListener() {},
  removeEventListener() {},
  getElementById: (id) => table.detailRows.get(id) || null,
  querySelector(selector) {
    const match = /^\.audit-row-toggle\[data-audit-key="(.*)"\]$/.exec(selector);
    if (match) return table.toggles.find((t) => t.dataset.auditKey === match[1]) || null;
    if (selector === '.sidebar') return null;
    return null;
  },
  querySelectorAll() { return []; },
};
globalThis.Stimulus = { Controller: class {} };
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };

let source = await readFile(new URL(process.argv[1]), 'utf8');
source = source.replace(/import \{[\s\S]*?\} from '\.\/shared\.js';/, `
const apiQs = () => '';
const applyIdenticons = () => {};
const closeAllCustomSelects = () => {};
const confirmDialog = async () => true;
const getApiToken = () => null;
const initCustomSelects = () => {};
const queueToast = () => {};
const readHtmxErrorMessage = () => '';
const renderMarkdown = () => {};
const scrollToBottom = () => {};
const showToast = () => {};
const TOAST_QUEUE_KEY = 'toast-queue';
const isAtBottom = () => false;
const reconcileRestartBanner = () => {};
const dismissRestartBannerState = () => {};
const syncRestartBannerAfterSwap = () => {};
`);

const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
// Unrelated shell wiring (sidebar, custom selects, SSE) is not under test here.
controller.initializeShellUi = () => {};

function expandedKeys() {
  return table.toggles.filter((t) => t.getAttribute('aria-expanded') === 'true').map((t) => t.dataset.auditKey);
}

function poll(nextKeys) {
  controller.handleBeforeSwap({ detail: { target: table.container } });
  table = makeTable(nextKeys);
  controller.handleAfterSwap({ detail: { target: table.container } });
}

// A real button click, not a row click: the <tr> carries no handler any more.
controller.toggleAuditRow(table.toggles[1]);
assert(table.detailRows.get('audit-detail-beta').hidden === false, 'toggle did not reveal the detail row');
assert(table.toggles[1].getAttribute('aria-expanded') === 'true', 'aria-expanded was not flipped');

// Two consecutive refreshes must each restore the same row and no other.
poll(['alpha', 'beta', 'gamma']);
assert(expandedKeys().join(',') === 'beta', 'first poll lost the expanded row: ' + expandedKeys());
assert(table.detailRows.get('audit-detail-beta').hidden === false, 'restored row is still hidden');

poll(['alpha', 'beta', 'gamma']);
assert(expandedKeys().join(',') === 'beta', 'second poll lost the expanded row: ' + expandedKeys());

// Reordering must follow the identity, not the position.
poll(['gamma', 'beta', 'alpha']);
assert(expandedKeys().join(',') === 'beta', 'reorder moved the expansion to another row: ' + expandedKeys());

// A near-collision pair must not be treated as the same row.
poll(['ab|c', 'a|bc']);
assert(expandedKeys().length === 0, 'a vanished entry transferred its expansion: ' + expandedKeys());
controller.toggleAuditRow(table.toggles[0]);
poll(['ab|c', 'a|bc']);
assert(expandedKeys().join(',') === 'ab|c', 'near-collision keys were confused: ' + expandedKeys());

// The entry the reader had open drops out of the page entirely.
poll(['a|bc']);
assert(expandedKeys().length === 0, 'removed identity left a row expanded: ' + expandedKeys());

// Collapsing is symmetric.
controller.toggleAuditRow(table.toggles[0]);
controller.toggleAuditRow(table.toggles[0]);
assert(table.detailRows.get('audit-detail-a|bc').hidden === true, 'second toggle did not collapse the row');
assert(table.toggles[0].getAttribute('aria-expanded') === 'false', 'collapse did not reset aria-expanded');
poll(['a|bc']);
assert(expandedKeys().length === 0, 'a collapsed row re-opened after a poll');

// A swap somewhere else on the page must not disturb the audit. The health
// page's own status region refreshes on its own 30s timer, so this fires
// routinely while the reader is looking at the table.
controller.toggleAuditRow(table.toggles[0]);
controller.handleAfterSwap({ detail: { target: { id: 'health-live' } } });
assert(expandedKeys().join(',') === 'a|bc', 'an unrelated swap collapsed the audit row');

// ...and the reader's collapse must stick. The restore key is only written by
// the audit's own beforeSwap, so a key left over from an earlier expansion
// would make the next unrelated swap re-open the row they just closed.
controller.toggleAuditRow(table.toggles[0]);
assert(expandedKeys().length === 0, 'toggle did not collapse the row');
controller.handleAfterSwap({ detail: { target: { id: 'health-live' } } });
assert(expandedKeys().length === 0, 'an unrelated swap re-opened a row the reader closed: ' + expandedKeys());
poll(['a|bc']);
assert(expandedKeys().length === 0, 'a poll re-opened a row the reader closed: ' + expandedKeys());

// Enter/Space need no bespoke keydown branch – the trigger is a real button.
const beforeKeydown = expandedKeys().join(',');
controller.handleDocumentKeydown({ key: 'Enter', target: { closest: () => { throw new Error('keydown still inspects .audit-row'); } } });
assert(expandedKeys().join(',') === beforeKeydown, 'keydown handler mutated audit state');
''';
