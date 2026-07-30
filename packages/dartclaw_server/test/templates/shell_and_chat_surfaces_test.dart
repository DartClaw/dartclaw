import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/session_info.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/topbar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

SidebarSession _session(String id, String provider) =>
    (id: id, title: 'Session $id', type: SessionType.user, provider: provider);

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('sidebar provider badges', () {
    test('are suppressed when every visible row shares one provider', () {
      final html = sidebarTemplate(
        mainSession: _session('main', 'claude'),
        activeEntries: [_session('s1', 'claude'), _session('s2', 'claude')],
        archivedEntries: [_session('s3', 'claude')],
      );

      // Six identical badges down the rail carry no discriminating information.
      expect(html, isNot(contains('class="provider-badge')));
      // Suppression is a rendering decision, not a data one — the rows are still there.
      expect(html, contains('Session s1'));
      expect(html, contains('Session s3'));
    });

    test('render on every row as soon as two providers disagree', () {
      final html = sidebarTemplate(
        mainSession: _session('main', 'claude'),
        activeEntries: [_session('s1', 'claude'), _session('s2', 'codex')],
      );

      expect(html, contains('provider-badge-claude'));
      expect(html, contains('provider-badge-codex'));
    });

    test('count a running task as a visible row for the uniformity decision', () {
      final html = sidebarTemplate(
        mainSession: _session('main', 'claude'),
        activeTasks: [
          (id: 't1', title: 'Task', status: 'running', startedAt: null, provider: 'codex', providerLabel: 'Codex'),
        ],
      );

      expect(html, contains('provider-badge-codex'));
    });

    test('publish the decision so a client-injected row cannot contradict it', () {
      expect(sidebarTemplate(mainSession: _session('main', 'claude')), contains('data-provider-badges="hidden"'));
      expect(
        sidebarTemplate(mainSession: _session('main', 'claude'), activeEntries: [_session('s1', 'codex')]),
        isNot(contains('data-provider-badges')),
      );
    });

    test('put the rail rows in canon\'s scroll region so overflow stays reachable', () {
      final html = sidebarTemplate(mainSession: _session('main', 'claude'), navItems: const []);

      // .sidebar is overflow:hidden; without this wrapper an expanded archive
      // clips the SYSTEM nav away with no scrollbar.
      expect(html, contains('<div class="session-list">'));
    });
  });

  group('turn-status panel', () {
    Map<String, dynamic> statusWith(Map<String, dynamic> overrides) => {
      'state': 'waiting',
      'session_id': 'sess-1',
      'turn_id': 'turn-1',
      'can_cancel': true,
      ...overrides,
    };

    test('formats each time and never leaks a raw ISO string', () {
      final view = sessionTurnStatusView(
        statusWith({
          'waiting_since': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(),
          'stuck_since': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
          'global_timeout_at': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
        }),
        fallbackSessionId: 'sess-1',
      );

      expect(view!['waitingSince'], '5m ago');
      expect(view['stuckSince'], '2h ago');
      expect(view.values.join(' '), isNot(contains('T')));
    });

    test('renders the timeout as remaining time, not as "just now"', () {
      final view = sessionTurnStatusView(
        statusWith({
          'global_timeout_at': DateTime.now().add(const Duration(minutes: 4, seconds: 30)).toIso8601String(),
        }),
        fallbackSessionId: 'sess-1',
      );

      // formatRelativeTime is past-only: every branch needs a positive elapsed
      // duration, so routing a future instant through it would read "just now"
      // — reporting an unexpired deadline as already reached.
      expect(view!['globalTimeoutAt'], 'in 4m');
      expect(view['globalTimeoutAt'], isNot('just now'));
    });

    test('never reports more remaining time than is left', () {
      String? remaining(Duration d) =>
          sessionTurnStatusView(
                statusWith({'global_timeout_at': DateTime.now().add(d).toIso8601String()}),
                fallbackSessionId: 'sess-1',
              )!['globalTimeoutAt']
              as String?;

      // Overstating a deadline is the harmful direction, so each reading floors.
      expect(remaining(const Duration(minutes: 61)), 'in 1h');
      expect(remaining(const Duration(hours: 25)), 'in 1d');
      expect(remaining(const Duration(seconds: 30)), 'in under a minute');
    });

    test('omits a slot that is absent rather than labelling a blank', () {
      final view = sessionTurnStatusView(
        statusWith({
          'waiting_since': DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String(),
          'stuck_since': null,
        }),
        fallbackSessionId: 'sess-1',
      );

      expect(view!['waitingSince'], isNotEmpty);
      expect(view['stuckSince'], isEmpty);
      expect(view['globalTimeoutAt'], isEmpty);
    });

    test('omits an unparseable value instead of printing it', () {
      final view = sessionTurnStatusView(statusWith({'waiting_since': 'not-a-timestamp'}), fallbackSessionId: 'sess-1');

      expect(view!['waitingSince'], isEmpty);
    });

    test('omits a timeout that has already passed', () {
      final view = sessionTurnStatusView(
        statusWith({'global_timeout_at': DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String()}),
        fallbackSessionId: 'sess-1',
      );

      expect(view!['globalTimeoutAt'], isEmpty);
    });
  });

  group('topbar restart slot', () {
    test('every topbar variant emits exactly one slot holding one banner node', () {
      for (final html in [
        topbarTemplate(appName: 'DartClaw'),
        topbarTemplate(title: 'Chat', sessionId: 's1', sessionType: SessionType.user),
        pageTopbarTemplate(title: 'Settings'),
      ]) {
        expect(RegExp('id="restart-banner-slot"').allMatches(html), hasLength(1));
        expect(RegExp('id="restart-banner"').allMatches(html), hasLength(1));
        // Dormant by default: hidden, inert and field-empty.
        expect(html, contains('hidden=""'));
        expect(html, contains('inert=""'));
      }
    });

    test('the slot follows the topbar so both are replaced as siblings', () {
      final html = pageTopbarTemplate(title: 'Settings');

      expect(html.indexOf('id="topbar"'), lessThan(html.indexOf('id="restart-banner-slot"')));
      expect(html.trimRight(), endsWith('</div>'));
    });

    test('a supplied pending banner renders live in the same slot', () {
      final html = pageTopbarTemplate(
        title: 'Settings',
        restartBannerHtml:
            '<div class="banner banner-restart" id="restart-banner">'
            '<strong id="restart-banner-fields">port</strong></div>',
      );

      expect(RegExp('id="restart-banner-slot"').allMatches(html), hasLength(1));
      expect(RegExp('id="restart-banner"').allMatches(html), hasLength(1));
      expect(html, contains('port'));
      // The caller's markup is used as-is, never duplicated beside a dormant one.
      expect(html, isNot(contains('inert')));
    });
  });
}
