import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  const session = (id: 's-1', title: '<unsafe>', type: SessionType.user, provider: 'claude');

  test('a conversation row carries three lines and one settle/archive pair', () {
    final html = sidebarTemplate(activeEntries: const [session]);

    expect(html, contains('data-inbox-session-id="s-1"'));
    // The three lines the controller paints: project/time, title/state, reason.
    for (final slot in [
      'data-inbox-project',
      'data-inbox-model',
      'data-inbox-time',
      'data-inbox-state',
      'data-inbox-reason',
    ]) {
      expect(html, contains(slot), reason: '$slot is the hook the shell controller paints into');
    }
    expect(html, contains('data-inbox-settle'));
    expect(html, contains('data-session-archive="true"'));
    // The checkbox ships with every row and select mode reveals it; a row that
    // only grows one on demand cannot keep its columns aligned. Its cell is a
    // label, which is what makes the whole 24px column a click target.
    expect(html, contains('data-inbox-select'));
    expect(html, contains('<label class="row-check">'));
    expect(html, contains('&lt;unsafe&gt;'));
  });

  test('view options offer every filter and grouping the controller applies', () {
    final html = sidebarTemplate(activeEntries: const [session]);

    for (final filter in ['all', 'unread', 'waiting', 'running', 'failed', 'drafts']) {
      expect(html, contains('data-inbox-filter="$filter"'));
      expect(html, contains('data-inbox-count="$filter"'));
    }
    for (final group in ['none', 'project', 'status']) {
      expect(html, contains('data-inbox-group="$group"'));
    }
    expect(html, contains('data-inbox-select-toggle'));
    // `data-inbox-select-mode` is the list's state attribute, written by the
    // controller. Markup carrying it too made every click inside the list match
    // the command hook, so the rail toggled the mode instead of selecting a row.
    expect(html, isNot(contains('data-inbox-select-mode')));
    // The <select> and the always-visible "Next attention" / "Settle selected"
    // stack this menu replaced.
    expect(html, isNot(contains('data-inbox-filters')));
    expect(html, isNot(contains('<select class="form-select" name="filter"')));
  });

  test('the rail keeps the surfaces the shell controller drives', () {
    final html = sidebarTemplate(activeEntries: const [session]);

    for (final hook in [
      'data-next-attention',
      'data-waiting-total',
      'data-inbox-announcer',
      'data-inbox-scope',
      'data-inbox-scope-menu',
      'data-settled-section',
      'data-settled-list',
      'data-settled-next',
      'data-inbox-bulk',
      'data-inbox-settle-selected',
      'data-device-drafts',
      'Drafts on this device',
    ]) {
      expect(html, contains(hook));
    }
  });

  test('the resize handle and scrim are siblings of the clipping rail', () {
    final html = sidebarTemplate(activeEntries: const [session]);

    // The rail sets overflow:hidden, so a handle straddling its border has to
    // sit outside it or be cut in half.
    expect(html.indexOf('</aside>'), lessThan(html.indexOf('sidebar-resize-handle')));
    expect(html.indexOf('sidebar-resize-handle'), lessThan(html.indexOf('sidebar-scrim')));
    expect(html, contains('aria-valuemin="240"'));
    expect(html, contains('aria-valuemax="420"'));
    expect(html, contains('aria-valuenow="280"'));
  });

  test('the resize handle generates its own box inside the shell', () async {
    final html = sidebarTemplate(activeEntries: const [session]);
    final css = File(p.join(await resolveStaticDir(), 'app.css')).readAsStringSync();

    // `.shell > div { display: contents }` strips the box off every div the
    // shell holds. A handle with no box has its absolutely-positioned ::before
    // resolve against .shell instead — a full-height invisible overlay over the
    // rail that swallows clicks and starts a drag from anywhere. The handle is
    // therefore not a div, and that is the whole reason.
    expect(
      css,
      contains('.shell > div { display: contents; }'),
      reason: 'the rule this element shape exists to avoid is gone; re-check the handle',
    );
    expect(html, contains('<hr class="sidebar-resize-handle"'));
    expect(html, isNot(contains('<div class="sidebar-resize-handle"')));
  });
}
