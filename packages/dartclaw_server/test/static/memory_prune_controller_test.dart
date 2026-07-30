import 'dart:io';

import 'package:test/test.dart';

/// "Prune Now" archives and de-duplicates the agent's memory, so every state it
/// passes through has to stay readable without colour. The states are asserted
/// behaviourally – a source grep for `style.color` cannot tell a class swap that
/// works from one that names a variant nothing paints.
void main() {
  final controller = File('packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js').existsSync()
      ? File('packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js')
      : File('lib/src/static/controllers/dc_memory_controller.js');

  test('prune states swap button variants and never paint inline colour', () async {
    ProcessResult result;
    try {
      result = await Process.run('node', [
        '--input-type=module',
        '--eval',
        _pruneHarness,
        controller.absolute.uri.toString(),
      ]);
    } on ProcessException {
      markTestSkipped('Node is unavailable');
      return;
    }

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });
}

const _pruneHarness = r'''
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
  toString() { return [...this.names].join(' '); }
}

// A style object that refuses to be written to: any inline colour assignment
// the controller still makes fails the test where it happens.
const style = new Proxy({}, {
  set(_target, prop) { throw new Error('controller assigned element.style.' + String(prop)); },
  get() { return ''; },
});

function makeButton() {
  return { textContent: 'Prune Now', disabled: false, dataset: {}, classList: new ClassList('btn', 'btn-danger'), style };
}

const timers = [];
globalThis.window = { setTimeout: (fn) => { timers.push(fn); return timers.length; } };
globalThis.document = { getElementById: () => null, addEventListener() {}, removeEventListener() {} };
globalThis.Stimulus = { Controller: class {} };
globalThis.localStorage = { getItem: () => null, setItem() {} };
globalThis.htmx = { ajax() {} };

let fetchOutcome = 'ok';
globalThis.fetch = async () => {
  if (fetchOutcome === 'throw') throw new Error('network down');
  return { ok: fetchOutcome === 'ok', json: async () => ({}), text: async () => '' };
};

const source = await readFile(new URL(process.argv[1]), 'utf8');
const module = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const controller = new module.default();
controller.element = { addEventListener() {}, querySelectorAll: () => [] };

function variant(button) {
  return [...button.classList.names].filter((n) => n !== 'btn').join(' ');
}

// Rest -> armed. The label changes, so the state is not carried by colour.
let button = makeButton();
controller.confirmPrune({ currentTarget: button });
assert(button.textContent === 'Confirm Prune?', 'arming did not relabel the button');
assert(variant(button) === 'btn-danger-fill', 'armed state is not a button variant: ' + variant(button));
assert(button.dataset.confirming === '1', 'arming did not record the confirm step');

// The 4s arm window expires back to rest, not to a half-armed button.
timers.pop()();
assert(button.textContent === 'Prune Now', 'arm timeout did not restore the label');
assert(variant(button) === 'btn-danger', 'arm timeout did not restore the resting variant');
assert(button.dataset.confirming === undefined, 'arm timeout left the confirm flag set');
assert(button.disabled === false, 'arm timeout left the button disabled');

// Armed -> confirmed runs the prune and locks the control while in flight.
button = makeButton();
controller.confirmPrune({ currentTarget: button });
controller.confirmPrune({ currentTarget: button });
assert(button.textContent === 'Pruning...', 'confirming did not report progress');
assert(button.disabled === true, 'the in-flight button stayed clickable');
await new Promise((resolve) => setTimeout(resolve, 0));
assert(button.textContent === 'Done!', 'success state was not reported: ' + button.textContent);
assert(variant(button) === 'btn-ghost', 'success state is not a button variant: ' + variant(button));

timers.pop()();
assert(button.textContent === 'Prune Now' && variant(button) === 'btn-danger', 'success did not reset to rest');
assert(button.disabled === false, 'success reset left the button disabled');

// A failed request is distinguishable by label and variant, again without colour.
fetchOutcome = 'throw';
button = makeButton();
controller.confirmPrune({ currentTarget: button });
controller.confirmPrune({ currentTarget: button });
await new Promise((resolve) => setTimeout(resolve, 0));
assert(button.textContent === 'Failed', 'failure state was not reported: ' + button.textContent);
assert(variant(button) === 'btn-danger-fill', 'failure state is not a button variant: ' + variant(button));
timers.pop()();
assert(button.textContent === 'Prune Now' && variant(button) === 'btn-danger', 'failure did not reset to rest');

// A non-2xx response is a failure too, not a silent success.
fetchOutcome = 'error';
button = makeButton();
controller.confirmPrune({ currentTarget: button });
controller.confirmPrune({ currentTarget: button });
await new Promise((resolve) => setTimeout(resolve, 0));
assert(button.textContent === 'Failed', 'a non-ok response reported success: ' + button.textContent);

// Every state resolved to exactly one variant – none left the button bare.
assert(variant(makeButton()) === 'btn-danger', 'the resting markup variant drifted from the template');
''';
