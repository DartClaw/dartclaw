import 'package:test/test.dart';

import 'controller_test_support.dart';

/// The citation popover opens on hover, so it needs a close path that survives
/// the gap between the marker and the popover, and a teardown that does not
/// outlive an HTMX swap. Driven by synthetic pointer and key events against a
/// minimal DOM stub — no browser, no htmx.
void main() {
  final controller = controllerAsset('dc_attribution_controller.js');

  test('hover dismissal, Escape, click pinning and teardown all hold', () async {
    await expectNodeHarness(_attributionHarness, [controller.absolute.uri.toString()]);
  });
}

const _attributionHarness = r'''
function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Minimal document stub that records listeners so teardown can be asserted.
const listeners = [];
globalThis.document = {
  addEventListener(type, fn, capture) { listeners.push({ type, fn, capture }); },
  removeEventListener(type, fn, capture) {
    const i = listeners.findIndex((l) => l.type === type && l.fn === fn && l.capture === capture);
    if (i !== -1) listeners.splice(i, 1);
  },
  fire(type, event) {
    listeners.filter((l) => l.type === type).forEach((l) => l.fn(event));
  },
  count(type) { return listeners.filter((l) => l.type === type).length; },
};

globalThis.Stimulus = { Controller: class {} };

const module = await import(process.argv[2] ?? process.argv[1]);
const DcAttributionController = module.default;

function makeController() {
  const popover = { hidden: true };
  const inside = {};
  const element = { contains: (node) => node === inside || node === popover };
  const c = new DcAttributionController();
  c.element = element;
  c.hasPopoverTarget = true;
  c.popoverTarget = popover;
  c.connect();
  return { c, popover, inside };
}

// 1. Hover open, pointer away -> closes after the delay, not before.
{
  const { c, popover } = makeController();
  c.show();
  assert(popover.hidden === false, 'hover should open the popover');
  c.scheduleHide();
  assert(popover.hidden === false, 'must not close synchronously — the pointer needs to reach the popover');
  await sleep(220);
  assert(popover.hidden === true, 'hover-opened popover should close after the delay');
  c.disconnect();
}

// 2. Re-entry cancels the pending close (marker -> popover travel).
{
  const { c, popover } = makeController();
  c.show();
  c.scheduleHide();
  c.cancelClose();
  await sleep(220);
  assert(popover.hidden === false, 're-entering must cancel the pending close');
  c.disconnect();
}

// 3. marker -> marker -> marker leaves exactly one open and no stale timer.
{
  const a = makeController();
  const b = makeController();
  const d = makeController();

  a.c.show();
  a.c.scheduleHide();
  b.c.show();
  b.c.scheduleHide();
  d.c.show();

  await sleep(220);
  const open = [a, b, d].filter((x) => x.popover.hidden === false);
  assert(open.length === 1, `exactly one popover should remain open, got ${open.length}`);
  assert(open[0] === d, 'the last hovered marker should be the open one');
  assert(a.c.closeTimer === null && b.c.closeTimer === null, 'no stale close timer may remain');
  [a, b, d].forEach((x) => x.c.disconnect());
}

// 4. Escape closes a hover-opened popover, via a document listener.
{
  const { c, popover } = makeController();
  c.show();
  assert(document.count('keydown') === 1, 'Escape must be bound on document, not the marker');
  document.fire('keydown', { key: 'Escape' });
  assert(popover.hidden === true, 'Escape should close the popover');
  assert(document.count('keydown') === 0, 'the keydown listener must come off when it closes');
  c.disconnect();
}

// 5. A non-Escape key leaves it alone.
{
  const { c, popover } = makeController();
  c.show();
  document.fire('keydown', { key: 'a' });
  assert(popover.hidden === false, 'only Escape closes');
  c.disconnect();
}

// 6. The reachable pointer sequence: hover opens, the click on the same marker
//    pins, and pointer-out then leaves it open until a click elsewhere.
//    A pointer is always hovering when its click lands, so hover-then-click is
//    the only sequence a mouse or touch user can produce.
{
  const { c, popover } = makeController();
  c.show();
  assert(popover.hidden === false, 'hover should open');
  assert(c.pinned === false, 'hover alone must not pin');
  c.toggle({ preventDefault() {}, stopPropagation() {} });
  assert(popover.hidden === false, 'clicking an already-hovered marker must pin, not close');
  assert(c.pinned === true, 'the click should have pinned it');
  c.scheduleHide();
  await sleep(220);
  assert(popover.hidden === false, 'a pinned popover must not close on pointer-out');
  document.fire('click', { target: {} });
  assert(popover.hidden === true, 'a click outside should close it');
  c.disconnect();
}

// 6b. A second click on a pinned popover closes it (toggle still toggles).
{
  const { c, popover } = makeController();
  c.show();
  c.toggle({ preventDefault() {}, stopPropagation() {} });
  assert(popover.hidden === false, 'first click pins');
  c.toggle({ preventDefault() {}, stopPropagation() {} });
  assert(popover.hidden === true, 'second click on a pinned popover closes it');
  assert(c.pinned === false, 'closing clears the pin');
  c.disconnect();
}

// 7. A click inside does not close it.
{
  const { c, popover, inside } = makeController();
  c.toggle({ preventDefault() {}, stopPropagation() {} });
  document.fire('click', { target: inside });
  assert(popover.hidden === false, 'a click inside must not close it');
  c.disconnect();
}

// 8. disconnect() removes every listener and clears a pending timer, so a
//    controller removed by an HTMX swap stops reacting.
{
  const { c } = makeController();
  c.show();
  c.scheduleHide();
  assert(document.count('click') === 1, 'click listener expected while open');
  assert(document.count('keydown') === 1, 'keydown listener expected while open');
  c.disconnect();
  assert(document.count('click') === 0, 'disconnect must remove the document click listener');
  assert(document.count('keydown') === 0, 'disconnect must remove the document keydown listener');
  assert(c.closeTimer === null, 'disconnect must clear the pending close timer');
  assert(listeners.length === 0, 'no orphaned listeners may survive disconnect');
}

console.log('attribution controller harness ok');
''';
