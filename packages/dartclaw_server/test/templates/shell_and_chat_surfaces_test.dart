import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_server/src/templates/chat.dart';
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

      // .sidebar is overflow:hidden; without this wrapper a long chat list
      // clips rows away instead of scrolling above the fixed footer.
      expect(html, contains('<div class="sidebar-body">'));
      expect(html, contains('<div class="session-list">'));
    });

    test('places a quiet full-width creation command beneath the Chats label', () {
      final html = sidebarTemplate(
        mainSession: _session('main', 'claude'),
        activeEntries: [_session('s1', 'codex')],
        navItems: const [],
      );

      expect(html, contains('<section class="sidebar-chat-section" aria-labelledby="sidebar-chats-label">'));
      expect(html, contains('<div class="sidebar-section-label" id="sidebar-chats-label">Chats</div>'));
      expect(html, contains('<button type="button" class="btn-new-session" data-session-create="true">'));
      expect(html, contains('<span class="btn-new-session-icon" data-icon="new-session" aria-hidden="true"></span>'));
      expect(html, contains('<span class="btn-new-session-label">New Chat</span>'));
      expect(html, contains('<hr class="sidebar-chat-divider">'));
      expect(html, isNot(contains('sidebar-section-heading')));
      expect(html, isNot(contains('class="btn btn-ghost btn-sm btn-new-session"')));

      final section = html.substring(
        html.indexOf('<section class="sidebar-chat-section"'),
        html.indexOf('</section>', html.indexOf('<section class="sidebar-chat-section"')),
      );
      expect(
        section.indexOf('id="sidebar-chats-label">Chats</div>'),
        lessThan(section.indexOf('class="btn-new-session"')),
      );
      expect(section.indexOf('class="btn-new-session"'), lessThan(section.indexOf('sidebar-chat-divider')));
      expect(section.indexOf('sidebar-chat-divider'), lessThan(section.indexOf('class="session-item"')));
    });

    test('distinguishes an untitled draft from the creation command and collapses system navigation', () {
      final html = sidebarTemplate(
        activeEntries: const [(id: 'draft', title: '', type: SessionType.user, provider: 'claude')],
        activeSessionId: 'draft',
        navItems: const [
          (label: 'Health', href: '/health-dashboard', active: true, navGroup: 'system', icon: 'health'),
          (label: 'Settings', href: '/settings', active: false, navGroup: 'system', icon: 'settings'),
        ],
      );

      expect(RegExp('New Chat').allMatches(html), hasLength(1));
      expect(html, contains('Untitled draft'));
      expect(html, contains('<details class="sidebar-system-menu">'));
      expect(html, contains('System · Health'));
      expect(html, contains('<nav class="sidebar-system-panel" aria-label="System navigation">'));
      expect(html, contains('aria-current="page"'));
    });

    test('keeps the workspace Agent identity outside mutable chat title sync', () {
      final html = sidebarTemplate(
        mainSession: (id: 'main', title: 'What is 42?', type: SessionType.main, provider: 'claude'),
        activeEntries: [_session('chat-1', 'claude')],
      );

      expect(html, contains('<span class="session-item-title">Agent</span>'));
      expect(html, isNot(contains('data-session-title-id="main"')));
      expect(html, contains('data-session-title-id="chat-1"'));
    });
  });

  test('session reset uses the destructive entry-point treatment', () {
    final html = topbarTemplate(title: 'Chat', sessionId: 'session-1', sessionType: SessionType.user);

    expect(html, contains('class="btn btn-danger btn-sm btn-reset"'));
  });

  test('uses the draft label for a blank session title', () {
    final html = topbarTemplate(title: '', sessionId: 'session-1', sessionType: SessionType.user);

    expect(html, contains('value="Untitled draft"'));
    expect(html, isNot(contains('value="New Chat"')));
  });

  test('keeps the workspace Agent identity static regardless of its persisted session title', () {
    final html = topbarTemplate(title: 'Renamed Session E2E', sessionId: 'session-1', sessionType: SessionType.main);

    expect(html, contains('<h1 class="session-title-static t-page-title">Agent</h1>'));
    expect(html, isNot(contains('id="session-title"')));
    expect(html, isNot(contains('Renamed Session E2E')));
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

    test('renders only active turn states', () {
      for (final state in ['idle', 'completed', 'cancelled', 'failed']) {
        expect(sessionTurnStatusView(statusWith({'state': state}), fallbackSessionId: 'sess-1'), isNull);
      }
      for (final state in ['running', 'waiting', 'stuck', 'cancelling']) {
        expect(sessionTurnStatusView(statusWith({'state': state}), fallbackSessionId: 'sess-1'), isNotNull);
      }
    });

    test('hides an unavailable cancel action without removing its live-update target', () {
      final html = chatAreaTemplate(
        sessionId: 'sess-1',
        messagesHtml: '',
        turnStatus: statusWith({'state': 'running', 'can_cancel': false}),
      );

      expect(html, contains('data-turn-cancel'));
      expect(html, contains('hidden=""'));
      expect(html, contains('disabled="disabled"'));
    });

    test('keeps an inert live-update mount when no turn is active', () {
      final html = chatAreaTemplate(
        sessionId: 'sess-1',
        messagesHtml: '',
        turnStatus: const {'session_id': 'sess-1', 'state': 'completed', 'can_cancel': false},
      );

      expect(html, contains('class="turn-status-panel" hidden=""'));
      expect(html, contains('data-turn-status-session-id="sess-1"'));
      expect(html, contains('data-turn-cancel'));
      expect(html, contains('disabled="disabled"'));
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
