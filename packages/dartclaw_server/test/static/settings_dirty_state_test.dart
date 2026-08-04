import 'package:test/test.dart';

import 'controller_test_support.dart';

/// Settings is the one surface that could lose operator work: it computed a
/// dirty flag and threw it away, so a tab switch discarded unsaved edits in
/// silence and Compact Instructions — a textarea — was never diffed or saved at
/// all. These tests drive the real functions and assert BEHAVIOUR: what the
/// operator sees on the form and its Save control, what the save payload
/// carries, and which forms a tab switch is about to hide.
///
/// Source-level assertions on the call-site wiring are a second layer, in
/// `app_js_test.dart`.
void main() {
  final controller = controllerAsset('dc_settings_controller.js');

  test('unsaved edits reach the form and Save, and a tab switch can see them', () async {
    await expectNodeHarness(_dirtyStateHarness, [controller.absolute.uri.toString()]);
  });
}

const _dirtyStateHarness = r'''
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// The module is imported for three exported functions, but its top level still
// touches these globals.
globalThis.Stimulus = { Controller: class {} };
globalThis.document = {
  querySelector: () => null,
  querySelectorAll: () => [],
  getElementById: () => null,
  addEventListener() {},
  removeEventListener() {},
  createElement: () => ({ style: {}, classList: { add() {}, remove() {}, toggle() {} }, appendChild() {}, remove() {} }),
  body: { appendChild() {}, removeChild() {} },
};
globalThis.window = globalThis;

const { formChanges, applyFormDirtyState, dirtyFormsLeaving } =
  await import(process.argv[2] ?? process.argv[1]);

// --- Minimal element stubs. Selectors match the production strings exactly, so
//     a change to either side breaks here rather than passing vacuously. ---

function control({ tag = 'INPUT', type = 'text', value = '' }) {
  return { tagName: tag, type, value, disabled: false, hidden: false };
}

function field(name, input, { toggle = false } = {}) {
  return {
    dataset: { field: name },
    querySelector(sel) {
      if (sel === '.form-toggle') return toggle ? {} : null;
      if (sel === 'input, select, textarea') return input;
      return null;
    },
  };
}

function form(fields, { saveButton = { disabled: true }, dataset = {} } = {}) {
  return {
    dataset,
    querySelectorAll(sel) {
      if (sel === '[data-field]') return fields;
      return [];
    },
    querySelector(sel) {
      if (sel === '.form-actions .btn-primary') return saveButton;
      return null;
    },
  };
}

// Production composition, in one place, exactly as updateFormDirtyState does it.
function refresh(f, config) {
  applyFormDirtyState(f, Object.keys(formChanges(f, config)).length > 0);
}

// (a) An edited text field marks the form dirty and enables Save.
{
  const input = control({ value: 'claude' });
  const save = { disabled: true };
  const f = form([field('agent.provider', input)], { saveButton: save });
  const config = { agent: { provider: 'claude' } };

  refresh(f, config);
  assert(f.dataset.dirty === 'false', 'a pristine form must not report unsaved edits');
  assert(save.disabled === true, 'Save must be inert with nothing to save');

  input.value = 'codex';
  refresh(f, config);
  assert(f.dataset.dirty === 'true', 'an edited field must mark the form dirty');
  assert(save.disabled === false, 'Save must become actionable while the value differs');
  assert(formChanges(f, config)['agent.provider'] === 'codex', 'the edit must reach the save payload');
}

// (b) A TEXTAREA does the same. getFieldInput queried only `input, select` for
//     the whole life of the feature, so Compact Instructions was never diffed
//     and never saved.
{
  const area = control({ tag: 'TEXTAREA', type: undefined, value: 'keep the decisions' });
  const save = { disabled: true };
  const f = form([field('context.compact_instructions', area)], { saveButton: save });
  const config = { context: { compactInstructions: 'keep the decisions' } };

  refresh(f, config);
  assert(f.dataset.dirty === 'false', 'an untouched textarea must not read as an edit');

  area.value = 'keep the decisions and the open questions';
  refresh(f, config);
  assert(f.dataset.dirty === 'true', 'an edited textarea must mark the form dirty');
  assert(save.disabled === false, 'Save must become actionable for a textarea edit');
  assert(
    formChanges(f, config)['context.compact_instructions'] === 'keep the decisions and the open questions',
    'the textarea edit must reach the save payload',
  );
}

// (c) Reverting an edit back to its initial value clears dirty and disables Save.
{
  const input = control({ type: 'number', value: '12' });
  const save = { disabled: true };
  const f = form([field('agent.max_turns', input)], { saveButton: save });
  const config = { agent: { maxTurns: 12 } };

  input.value = '42';
  refresh(f, config);
  assert(f.dataset.dirty === 'true' && save.disabled === false, 'the edit must arm Save');

  input.value = '12';
  refresh(f, config);
  assert(f.dataset.dirty === 'false', 'restoring the original value must clear the dirty flag');
  assert(save.disabled === true, 'Save must return to its non-actionable state');
  assert(Object.keys(formChanges(f, config)).length === 0, 'a restored value must not appear in the payload');
}

// (d) A cleared field diffs as unset and is SENT as unset. `''` on a nullable
//     field would persist an empty string rather than reset it.
{
  const input = control({ value: 'claude' });
  const f = form([field('agent.model', input)]);
  const config = { agent: { model: 'claude' } };

  input.value = '';
  const changes = formChanges(f, config);
  assert('agent.model' in changes, 'clearing a valued field is an edit');
  assert(changes['agent.model'] === null, `a cleared field must be sent as unset, got ${JSON.stringify(changes['agent.model'])}`);
}

// (d, converse) An untouched field that is unset in config reads as clean —
//     the control says '' and the config says null, and every form on the page
//     loaded dirty before both sides were folded together.
{
  const f = form([
    field('agent.model', control({ value: '' })),
    field('agent.effort', control({ tag: 'SELECT', type: undefined, value: '' })),
  ]);
  const config = { agent: { model: null } };  // effort absent entirely
  assert(Object.keys(formChanges(f, config)).length === 0,
    `unset fields must not read as edits, got ${JSON.stringify(formChanges(f, config))}`);
}

// A legitimate 0 is a value, not an absence.
{
  const input = control({ type: 'number', value: '0' });
  const f = form([field('sessions.reset_hour', input)]);
  assert(Object.keys(formChanges(f, { sessions: { resetHour: 0 } })).length === 0, '0 must equal 0');
  assert('sessions.reset_hour' in formChanges(f, { sessions: { resetHour: 3 } }), '0 must differ from 3');
}

// Toggles auto-save through handleToggleChange, so they stay out of the diff:
// including one would mark a card dirty for a change already persisted.
{
  const box = control({ type: 'checkbox', value: '' });
  box.checked = true;
  const f = form([field('workspace.git_sync.enabled', box, { toggle: true })]);
  assert(Object.keys(formChanges(f, { workspace: { gitSync: { enabled: false } } })).length === 0,
    'a toggle must never enter the dirty diff or the save payload');
}

// An in-flight save keeps Save inert even while the form is dirty, or typing
// during the request re-arms it and admits a duplicate PATCH.
{
  const save = { disabled: true };
  const f = form([field('host', control({ value: 'x' }))], { saveButton: save, dataset: { saving: 'true' } });
  applyFormDirtyState(f, true);
  assert(f.dataset.dirty === 'true', 'the flag still records the edit');
  assert(save.disabled === true, 'Save must stay inert while a save is in flight');
}

// (e) dirtyFormsLeaving returns the forms in the cards about to be hidden, and
//     never the incoming tab's.
{
  function card(tab, forms, { hidden = false } = {}) {
    return {
      dataset: { tab },
      hidden,
      querySelectorAll: (sel) => (sel === '.settings-form' ? forms : []),
    };
  }
  const dirtyAgent = { dataset: { dirty: 'true' }, name: 'agent' };
  const cleanMemory = { dataset: { dirty: 'false' }, name: 'memory' };
  const dirtyIncoming = { dataset: { dirty: 'true' }, name: 'providers' };
  const dirtyHidden = { dataset: { dirty: 'true' }, name: 'already-hidden' };

  const grid = {
    querySelectorAll: (sel) => (sel === '[data-tab]' ? [
      card('agent', [dirtyAgent]),
      card('memory', [cleanMemory]),
      card('providers', [dirtyIncoming]),
      card('sessions', [dirtyHidden], { hidden: true }),
      card('channels', []),                 // a tab with no form at all
    ] : []),
  };
  const config = { agent: {} };

  const leaving = dirtyFormsLeaving(grid, 'providers', config);
  assert(leaving.length === 1, `expected exactly one dirty form leaving, got ${leaving.map(f => f.name)}`);
  assert(leaving[0] === dirtyAgent, 'the dirty form in the outgoing card must be returned');
  assert(!leaving.includes(dirtyIncoming), 'the incoming tab must never be asked to discard');
  assert(!leaving.includes(dirtyHidden), 'an already-hidden card is not being hidden again');
  assert(!leaving.includes(cleanMemory), 'a clean form is nothing to discard');

  // Switching to a tab whose own card is dirty still warns about the others.
  assert(dirtyFormsLeaving(grid, 'agent', config).length === 1, 'the other dirty card still guards');

  // No baseline means the flags can only be stale markup restored from a
  // history snapshot; discarding from them would be a no-op and the dialog
  // would re-fire on every departure.
  assert(dirtyFormsLeaving(grid, 'providers', null).length === 0, 'no baseline, no dialog');
  assert(dirtyFormsLeaving(null, 'providers', config).length === 0, 'no grid, no dialog');
}

console.log('settings dirty state harness ok');
''';
