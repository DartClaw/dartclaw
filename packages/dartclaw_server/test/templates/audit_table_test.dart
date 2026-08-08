import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/audit/audit_log_reader.dart';
import 'package:dartclaw_server/src/templates/audit_table.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

AuditEntry _entry({
  DateTime? timestamp,
  String guard = 'CommandGuard',
  String hook = 'preToolUse',
  String verdict = 'block',
  String? reason,
  String? sessionId,
  String? channel,
  String? peerId,
}) => AuditEntry(
  timestamp: timestamp ?? DateTime.utc(2026, 4, 15, 10),
  guard: guard,
  hook: hook,
  verdict: verdict,
  reason: reason,
  sessionId: sessionId,
  channel: channel,
  peerId: peerId,
);

AuditPage _page(List<AuditEntry> entries, {int currentPage = 1, int totalPages = 1}) => AuditPage(
  entries: entries,
  totalEntries: entries.length,
  currentPage: currentPage,
  totalPages: totalPages,
  pageSize: 25,
);

/// The key is opaque by design; the tests decode it so a failure names the field
/// that collided rather than reporting two unequal base64 blobs.
List<dynamic> _decodeKey(String key) {
  final padded = key.padRight(key.length + (4 - key.length % 4) % 4, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded))) as List<dynamic>;
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('guard audit table', () {
    test('adopts the canonical table, chip filters and shared empty state', () {
      final populated = auditTableFragment(auditPage: _page([_entry(reason: 'rm -rf denied')]));

      expect(populated, contains('<table class="data-table">'));
      // The private filter-button recipe and its inline spacer are gone; the
      // toolbar is two canon chip rows.
      expect(populated, isNot(contains('filter-btn')));
      expect(populated, isNot(contains('style="margin-left:auto"')));
      expect(populated, contains('class="chip"'));
      expect(RegExp('aria-pressed=').allMatches(populated), hasLength(9));

      final empty = auditTableFragment(auditPage: AuditPage.empty);
      expect(empty, contains('class="empty-state"'));
      expect(empty, contains('class="empty-state-title'));
      expect(empty, contains('No guard events recorded yet'));
      // An empty page under a filter is "nothing matched", not "nothing
      // happened" – the operator filtering by Block on a healthy system must
      // not be told the log is empty.
      for (final filtered in [
        auditTableFragment(auditPage: AuditPage.empty, verdictFilter: 'block'),
        auditTableFragment(auditPage: AuditPage.empty, guardFilter: 'file'),
      ]) {
        expect(filtered, contains('No guard events match the current filters'));
        expect(filtered, isNot(contains('No guard events recorded yet')));
      }
      // The shared fragment supplies the decorative icon; the audit hand-authors
      // neither markup nor an inline style override of its own.
      expect(empty, contains('class="icon" aria-hidden="true"'));
      expect(empty, isNot(contains('style="padding:')));
      expect(empty, isNot(contains('table-empty-cell')));
    });

    test('the row disclosure is a button wired to its own detail row', () {
      final html = auditTableFragment(auditPage: _page([_entry(sessionId: 'sess-1')]));
      final key = auditEntryKey(_entry(sessionId: 'sess-1'));

      expect(html, isNot(contains('role="button"')));
      expect(html, isNot(contains('tabindex="0"')));
      expect(html, contains('<button type="button" class="btn btn-ghost btn-icon-sm audit-row-toggle"'));
      expect(html, contains('aria-expanded="false"'));
      expect(html, contains('data-audit-key="$key"'));
      expect(html, contains('aria-controls="audit-detail-$key-0"'));
      expect(html, contains('<tr class="audit-detail-row" id="audit-detail-$key-0" hidden>'));
      // Collapsed via the `hidden` attribute, not an inline display style.
      expect(html, isNot(contains('style="display:none"')));
    });

    test('a row with nothing to disclose gets a spacer, not an empty disclosure', () {
      // The Detail column already prints the hook for a row with no reason, so
      // a chevron there would open a panel repeating it beside three dashes.
      final bare = _entry(verdict: 'pass', reason: null);
      final html = auditTableFragment(auditPage: _page([bare]));

      expect(html, isNot(contains('audit-row-toggle"')));
      expect(html, isNot(contains('audit-detail-row')));
      expect(html, isNot(contains('aria-expanded')));
      expect(html, isNot(contains('aria-controls')));
      // The timestamp column still lines up with rows that do open.
      expect(html, contains('<span class="audit-row-toggle-spacer" aria-hidden="true"></span>'));

      // Any one of the four detail fields brings the disclosure back.
      for (final entry in [
        _entry(reason: 'denied'),
        _entry(reason: null, sessionId: 's'),
        _entry(reason: null, channel: 'c'),
        _entry(reason: null, peerId: 'p'),
      ]) {
        final withDetail = auditTableFragment(auditPage: _page([entry]));
        expect(withDetail, contains('audit-row-toggle"'), reason: 'disclosure missing for ${auditEntryKey(entry)}');
        expect(withDetail, contains('audit-detail-row'));
        expect(withDetail, isNot(contains('audit-row-toggle-spacer')));
      }
    });

    test('two entries the reader cannot tell apart still get their own detail row', () {
      // The log does not de-duplicate and its entries carry no id, so a page can
      // legitimately hold two rows identical in all eight rendered fields. They
      // share a restore key by definition; duplicate element ids would make one
      // row's chevron open the other row's detail.
      final twin = _entry(reason: 'same reason');
      final html = auditTableFragment(auditPage: _page([twin, twin]));

      final ids = RegExp('id="(audit-detail-[^"]+)"').allMatches(html).map((m) => m.group(1)).toList();
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(2), reason: 'duplicate ids: aria-controls would resolve to the first row');

      final controls = RegExp('aria-controls="([^"]+)"').allMatches(html).map((m) => m.group(1)).toList();
      expect(controls, ids, reason: 'each toggle must point at its own row');
    });

    test('timestamps render in the shared format with the ISO instant disclosed', () {
      final html = auditTableFragment(auditPage: _page([_entry(timestamp: DateTime.utc(2020, 3, 20, 14, 5, 3))]));

      expect(html, contains('<time datetime="2020-03-20T14:05:03.000Z"'));
      expect(html, contains('title="2020-03-20T14:05:03.000Z"'));
      // The private "Mar 20 14:05" / "14:05:03" pair is gone: past 30 days the
      // shared formatter rolls over to an absolute short date.
      expect(html, contains('>20 Mar 2020<'));
      expect(html, isNot(contains('>14:05:03<')));
    });

    test('the fragment states its own htmx target and select', () {
      final html = auditTableFragment(auditPage: _page([_entry()]));

      // Both attributes are inheritable and the health page's refresh wrapper
      // declares `hx-target="this" hx-select=".content-inner"`. Inherited, the
      // 30s poll replaces the entire dashboard with this table and then selects
      // a `.content-inner` the response does not contain – blanking the page on
      // a timer, and blanking the table on every filter click.
      expect(
        html,
        contains('hx-target="this" hx-select="#audit-table-container" hx-swap="outerHTML"'),
        reason: 'the audit poll must scope itself, not inherit the page wrapper target',
      );
      // The controls inside inherit the container's select, so a filter or page
      // change resolves against the audit response rather than the page.
      final containerOpen = html.indexOf('<div id="audit-table-container"');
      final firstChip = html.indexOf('class="chip"');
      expect(firstChip, greaterThan(containerOpen));
      expect(html, contains('hx-target="#audit-table-container" hx-swap="outerHTML"'));
    });

    test('the poll keeps the reader on their page with both filters applied', () {
      final html = auditTableFragment(
        auditPage: _page([_entry()], currentPage: 2, totalPages: 3),
        verdictFilter: 'block',
        guardFilter: 'file',
      );

      // `&` is written as an entity because this is an HTML attribute value.
      expect(
        html,
        contains('hx-get="/health-dashboard/audit?guard=file&amp;verdict=block&amp;page=2" hx-trigger="every 30s"'),
      );
      // Always on: no cancellation, pause attribute or conditional trigger.
      expect(html, isNot(contains('hx-trigger="every 30s [')));
      expect(html, isNot(contains('hx-sync')));
      expect(html, isNot(contains('htmx:beforeRequest')));
    });

    test('page 1 polls without a page parameter, and a filter change restarts paging', () {
      final firstPage = auditTableFragment(auditPage: _page([_entry()]), guardFilter: 'file');
      expect(firstPage, contains('hx-get="/health-dashboard/audit?guard=file" hx-trigger="every 30s"'));

      final deepPage = auditTableFragment(auditPage: _page([_entry()], currentPage: 4, totalPages: 9));
      // A filter chip's own URL carries no page: a different result set cannot
      // honour the page number the reader was on.
      expect(deepPage, contains('hx-get="/health-dashboard/audit?guard=command"'));
      expect(deepPage, isNot(contains('/health-dashboard/audit?guard=command&amp;page=4')));
    });

    test('a hostile filter value cannot break out of the hx-get attribute', () {
      // Both filters reach this fragment straight off the query string
      // (`web_routes.dart` and `health_page.dart` pass `params[...]` through), so
      // an unescaped value would inject further htmx attributes into an
      // authenticated page – and an injected `hx-trigger` placed before the
      // fragment's own would be the one the parser keeps.
      const hostile = '" hx-delete="/api/sessions/victim" hx-trigger="load" x="';
      final html = auditTableFragment(auditPage: _page([_entry()]), guardFilter: hostile);

      // Nothing may reach the markup as attribute syntax.
      expect(html, isNot(contains('hx-delete="')));
      expect(html, isNot(contains('hx-trigger="load"')));
      // The container keeps exactly one poll trigger – an injected one placed
      // earlier in the tag is the one a parser would honour.
      final container = RegExp('<div id="audit-table-container"[^>]*>').firstMatch(html)!.group(0)!;
      expect(RegExp('hx-trigger=').allMatches(container), hasLength(1));
      expect(container, contains('hx-trigger="every 30s"'));
      // The quote that would have closed the attribute is encoded, so the whole
      // hostile string stays inside the hx-get value.
      expect(container, contains('guard=%22'));
      final hxGet = RegExp('hx-get="([^"]*)"').firstMatch(container)!.group(1)!;
      expect(hxGet, isNot(contains('"')));
      expect(hxGet, isNot(contains(' ')));
    });
  });

  group('audit row presentation key', () {
    test('distinguishes field boundaries that a delimiter join would collide', () {
      final ab = auditEntryKey(_entry(sessionId: 'ab', channel: 'c'));
      final aB = auditEntryKey(_entry(sessionId: 'a', channel: 'bc'));

      expect(ab, isNot(aB), reason: 'concatenating the tuple would make these one key');
      expect(_decodeKey(ab)[4], 'ab');
      expect(_decodeKey(aB)[4], 'a');
    });

    test('distinguishes a null field from an empty one, and survives a delimiter inside a field', () {
      expect(auditEntryKey(_entry(sessionId: null)), isNot(auditEntryKey(_entry(sessionId: ''))));
      expect(auditEntryKey(_entry(reason: 'a|b')), isNot(auditEntryKey(_entry(reason: 'a', peerId: 'b'))));
      expect(auditEntryKey(_entry(peerId: 'x:y')), isNot(auditEntryKey(_entry(peerId: 'x', channel: 'y'))));
    });

    test('is stable across renders and independent of row position', () {
      final entries = [_entry(sessionId: 'one'), _entry(sessionId: 'two'), _entry(sessionId: 'three')];
      final forward = auditTableFragment(auditPage: _page(entries));
      final reordered = auditTableFragment(auditPage: _page(entries.reversed.toList()));

      for (final entry in entries) {
        final key = auditEntryKey(entry);
        expect(forward, contains('data-audit-key="$key"'));
        expect(reordered, contains('data-audit-key="$key"'));
      }
    });

    test('covers every field the row and its detail render', () {
      final base = _entry();
      final variants = {
        'timestamp': _entry(timestamp: DateTime.utc(2026, 4, 15, 11)),
        'guard': _entry(guard: 'FileGuard'),
        'hook': _entry(hook: 'postToolUse'),
        'verdict': _entry(verdict: 'warn'),
        'reason': _entry(reason: 'denied'),
        'sessionId': _entry(sessionId: 's'),
        'channel': _entry(channel: 'c'),
        'peerId': _entry(peerId: 'p'),
      };
      for (final entry in variants.entries) {
        expect(
          auditEntryKey(entry.value),
          isNot(auditEntryKey(base)),
          reason: '${entry.key} is rendered but does not reach the key',
        );
      }
    });
  });
}
