import 'dart:io';

import 'package:test/test.dart';

/// The channel access-mode pickers are radiogroups, so arrow keys move
/// selection on every keypress. `dm_access` decides who may message the agent,
/// so a naive per-change write would briefly persist access policies the
/// operator only passed through. These tests pin the two properties that stop
/// that: transit values are never written, and a failed write rolls back to the
/// value that was committed when *that* request was dispatched.
///
/// Driven with injected timers — no clock, no DOM, no network.
void main() {
  final controller = File('packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js').existsSync()
      ? File('packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js')
      : File('lib/src/static/controllers/dc_settings_controller.js');

  test('debounce drops transit modes and serialized writes roll back correctly', () async {
    ProcessResult result;
    try {
      result = await Process.run('node', [
        '--input-type=module',
        '--eval',
        _schedulerHarness,
        controller.absolute.uri.toString(),
      ]);
    } on ProcessException catch (error) {
      fail('Node.js is required for controller tests: $error');
    }

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });
}

const _schedulerHarness = r'''
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// The module is imported for one exported factory, but its top level still
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

const { createModeCommitScheduler } = await import(process.argv[2] ?? process.argv[1]);

// Controllable clock: timers fire only when we say so.
function makeClock() {
  let next = 1;
  const timers = new Map();
  return {
    set: (fn, delay) => { const id = next++; timers.set(id, { fn, delay }); return id; },
    clear: (id) => { timers.delete(id); },
    pendingCount: () => timers.size,
    // Fire every armed timer, as the real clock would after the delay elapses.
    tick() {
      const due = [...timers.entries()];
      timers.clear();
      due.forEach(([, t]) => t.fn());
    },
  };
}

function makeScheduler(initialValue, { autoResolve = true } = {}) {
  const clock = makeClock();
  const calls = [];
  const scheduler = createModeCommitScheduler({
    delayMs: 350,
    initialValue,
    setTimeoutFn: clock.set,
    clearTimeoutFn: clock.clear,
    patch(value, onSuccess, onError) {
      const call = { value, onSuccess, onError, settled: false };
      calls.push(call);
      if (autoResolve) { call.settled = true; onSuccess(); }
    },
    onCommitted: (v) => committed.push(v),
    onFailed: (rollbackTo, err) => failures.push({ rollbackTo, err }),
  });
  const committed = [];
  const failures = [];
  return { scheduler, clock, calls, committed, failures };
}

// 1. THE RULING'S CORE CASE: arrowing quickly through modes writes once, with
//    the value the operator rested on — no transit mode is ever persisted.
{
  const { scheduler, clock, calls, committed } = makeScheduler('disabled');
  // disabled -> open -> allowlist -> pairing, faster than the settle delay.
  scheduler.schedule('open');
  scheduler.schedule('allowlist');
  scheduler.schedule('pairing');
  assert(calls.length === 0, 'nothing may be written while the selection is still moving');
  assert(clock.pendingCount() === 1, 'each keypress must re-arm one timer, not stack them');

  clock.tick();
  assert(calls.length === 1, `expected exactly one write, got ${calls.length}: ${calls.map(c => c.value)}`);
  assert(calls[0].value === 'pairing', `expected the settled value, got ${calls[0].value}`);
  assert(!calls.some(c => c.value === 'open' || c.value === 'allowlist'), 'a transit mode was persisted');
  assert(committed.join() === 'pairing', 'onCommitted should report only the settled value');
  assert(scheduler.committedValue() === 'pairing');
  assert(scheduler.isIdle(), 'scheduler should be idle after the write lands');
}

// 2. Abandoning a traversal mid-way persists only where it stopped.
{
  const { scheduler, clock, calls } = makeScheduler('pairing');
  scheduler.schedule('open');
  scheduler.schedule('disabled');
  clock.tick();
  assert(calls.length === 1 && calls[0].value === 'disabled', 'only the resting mode is written');
}

// 3. Returning to the starting mode writes nothing at all.
{
  const { scheduler, clock, calls } = makeScheduler('allowlist');
  scheduler.schedule('open');
  scheduler.schedule('allowlist');
  clock.tick();
  assert(calls.length === 0, 'a round trip back to the committed value must not write');
}

// 4. SERIALIZATION: a selection made while a write is in flight waits for it,
//    then goes out as its own single request.
{
  const { scheduler, clock, calls, committed } = makeScheduler('disabled', { autoResolve: false });
  scheduler.schedule('open');
  clock.tick();
  assert(calls.length === 1 && calls[0].value === 'open', 'first write dispatched');

  scheduler.schedule('pairing');
  clock.tick();
  assert(calls.length === 1, 'a second request must not overlap the in-flight one');

  calls[0].onSuccess();
  assert(calls.length === 2, 'the queued selection should be drained on completion');
  assert(calls[1].value === 'pairing', `expected pairing, got ${calls[1].value}`);
  calls[1].onSuccess();
  assert(committed.join() === 'open,pairing');
  assert(scheduler.committedValue() === 'pairing');
}

// 5. ROLLBACK VALUE: each request captures its own rollback target, so a
//    failure restores the mode that was committed when it was dispatched —
//    not whatever the newest selection happened to be.
{
  const { scheduler, clock, calls, failures } = makeScheduler('disabled', { autoResolve: false });
  scheduler.schedule('open');
  clock.tick();                       // request A: disabled -> open
  calls[0].onSuccess();               // committed = open

  scheduler.schedule('pairing');
  clock.tick();                       // request B: open -> pairing
  assert(calls.length === 2);
  calls[1].onError({ error: { message: 'nope' } });

  assert(failures.length === 1, 'the failure should surface once');
  assert(failures[0].rollbackTo === 'open',
    `rollback must restore the value committed at dispatch (open), got ${failures[0].rollbackTo}`);
  assert(scheduler.committedValue() === 'open', 'a failed write must not advance the committed value');
}

// 6. A failure while another selection is queued rolls back and drops the
//    queue — the queued value was chosen against a state that never existed.
{
  const { scheduler, clock, calls, failures } = makeScheduler('disabled', { autoResolve: false });
  scheduler.schedule('open');
  clock.tick();                       // request A in flight
  scheduler.schedule('pairing');
  clock.tick();                       // queued behind A

  calls[0].onError({ error: { message: 'refused' } });
  assert(failures[0].rollbackTo === 'disabled', 'rollback to the pre-request value');
  assert(calls.length === 1, 'the queued selection must not be replayed after a rejection');
  assert(scheduler.committedValue() === 'disabled');
  assert(scheduler.isIdle(), 'no work should remain after a rejection');
}

// 7. cancel() disarms a pending write, so navigating away cannot land one late.
{
  const { scheduler, clock, calls } = makeScheduler('disabled');
  scheduler.schedule('pairing');
  assert(clock.pendingCount() === 1);
  scheduler.cancel();
  assert(clock.pendingCount() === 0, 'cancel must clear the armed timer');
  clock.tick();
  assert(calls.length === 0, 'a cancelled selection must never be written');
  assert(scheduler.committedValue() === 'disabled');
}

console.log('mode commit scheduler harness ok');
''';
