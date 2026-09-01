import 'package:test/test.dart';

import 'controller_test_support.dart';

/// Settings is the one surface that could lose operator work: a tab switch
/// hides a card, and an unguarded switch would discard unsaved edits in
/// silence. The values are server-rendered now, so the baseline is each
/// control's own default rather than a fetched config — these tests drive the
/// real functions and assert BEHAVIOUR: what the operator sees on the form and
/// its Save control, and which forms a tab switch is about to hide.
///
/// Source-level assertions on the call-site wiring are a second layer, in
/// `app_js_test.dart`.
void main() {
  final controller = controllerAsset('dc_settings_controller.js');

  test('unsaved edits reach the form and Save, and a tab switch can see them', () async {
    await expectNodeHarness(_dirtyStateHarness, [(await controller).absolute.uri.toString()]);
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
//     a change to either side breaks here rather than passing vacuously.
//     `defaultValue` / `defaultChecked` / `defaultSelected` are what the server
//     rendered into the control — the whole baseline. ---

function control({ tag = 'INPUT', type = 'text', value = '', disabled = false }) {
  return { tagName: tag, type, value, defaultValue: value, disabled, hidden: false };
}

function select(options, selectedValue) {
  return {
    tagName: 'SELECT',
    type: undefined,
    disabled: false,
    value: selectedValue,
    options: options.map((option) => ({ value: option.value, defaultSelected: !!option.defaultSelected })),
  };
}

function toggle(checked) {
  return { tagName: 'INPUT', type: 'checkbox', checked, defaultChecked: checked, disabled: false };
}

function field(name, input) {
  return {
    dataset: { field: name },
    querySelector(sel) {
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
function refresh(f) {
  applyFormDirtyState(f, formChanges(f).length > 0);
}

// (a) An edited text field marks the form dirty and enables Save.
{
  const input = control({ value: 'claude' });
  const save = { disabled: true };
  const f = form([field('agent.provider', input)], { saveButton: save });

  refresh(f);
  assert(f.dataset.dirty === 'false', 'a pristine form must not report unsaved edits');
  assert(save.disabled === true, 'Save must be inert with nothing to save');

  input.value = 'codex';
  refresh(f);
  assert(f.dataset.dirty === 'true', 'an edited field must mark the form dirty');
  assert(save.disabled === false, 'Save must become actionable while the value differs');
  assert(formChanges(f)[0] === 'agent.provider', 'the edited path must be reported');
}

// (b) A TEXTAREA does the same. getFieldInput queried only `input, select` for
//     the whole life of the feature, so Compact Instructions was never diffed.
{
  const area = control({ tag: 'TEXTAREA', type: undefined, value: 'keep the decisions' });
  const f = form([field('context.compact_instructions', area)]);

  refresh(f);
  assert(f.dataset.dirty === 'false', 'an untouched textarea must not read as an edit');

  area.value = 'keep the decisions and the open questions';
  refresh(f);
  assert(f.dataset.dirty === 'true', 'an edited textarea must mark the form dirty');
}

// (c) Reverting an edit back to the rendered value clears dirty and disables Save.
{
  const input = control({ type: 'number', value: '12' });
  const save = { disabled: true };
  const f = form([field('agent.max_turns', input)], { saveButton: save });

  input.value = '42';
  refresh(f);
  assert(f.dataset.dirty === 'true' && save.disabled === false, 'the edit must arm Save');

  input.value = '12';
  refresh(f);
  assert(f.dataset.dirty === 'false', 'restoring the rendered value must clear the dirty flag');
  assert(save.disabled === true, 'Save must return to its non-actionable state');
  assert(formChanges(f).length === 0, 'a restored value must not be reported as a change');
}

// (d) Clearing a valued field is an edit — that is how a nullable field is unset.
{
  const input = control({ value: 'claude' });
  const f = form([field('agent.model', input)]);

  input.value = '';
  assert(formChanges(f).includes('agent.model'), 'clearing a valued field is an edit');
}

// (d, converse) A field the server rendered empty reads as clean.
{
  const f = form([field('agent.model', control({ value: '' }))]);
  assert(formChanges(f).length === 0, 'an unset field must not read as an edit');
}

// A select compares against the option the server marked selected.
{
  const picker = select(
    [{ value: 'shared', defaultSelected: true }, { value: 'per-contact' }],
    'shared',
  );
  const f = form([field('sessions.dm_scope', picker)]);
  assert(formChanges(f).length === 0, 'the server-selected option is the baseline');

  picker.value = 'per-contact';
  assert(formChanges(f).includes('sessions.dm_scope'), 'choosing another option is an edit');
}

// A toggle now saves with its section rather than auto-saving, so it is part of
// the diff — excluding it would let a flipped switch be discarded in silence.
{
  const box = toggle(false);
  const f = form([field('scheduling.heartbeat.enabled', box)]);
  assert(formChanges(f).length === 0, 'an untouched toggle is not an edit');

  box.checked = true;
  assert(formChanges(f).includes('scheduling.heartbeat.enabled'), 'a flipped toggle must reach the diff');
}

// A read-only field renders no control at all; a disabled one is not settable,
// so neither can be an edit.
{
  const f = form([
    field('tasks.execution', null),
    field('search.providers', control({ value: 'x', disabled: true })),
  ]);
  assert(formChanges(f).length === 0, 'a non-editable field can never be dirty');
}

// An in-flight save keeps Save inert even while the form is dirty, or typing
// during the request re-arms it and admits a duplicate submission.
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

  const leaving = dirtyFormsLeaving(grid, 'providers');
  assert(leaving.length === 1, `expected exactly one dirty form leaving, got ${leaving.map(f => f.name)}`);
  assert(leaving[0] === dirtyAgent, 'the dirty form in the outgoing card must be returned');
  assert(!leaving.includes(dirtyIncoming), 'the incoming tab must never be asked to discard');
  assert(!leaving.includes(dirtyHidden), 'an already-hidden card is not being hidden again');
  assert(!leaving.includes(cleanMemory), 'a clean form is nothing to discard');

  // Switching to a tab whose own card is dirty still warns about the others.
  assert(dirtyFormsLeaving(grid, 'agent').length === 1, 'the other dirty card still guards');
  assert(dirtyFormsLeaving(null, 'providers').length === 0, 'no grid, no dialog');
}

console.log('settings dirty state harness ok');
''';
