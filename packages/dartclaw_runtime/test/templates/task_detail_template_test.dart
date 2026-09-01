import 'package:dartclaw_runtime/src/templates/helpers.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/templates/session_info.dart';
import 'package:dartclaw_runtime/src/templates/task_detail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final emptySidebar = (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    activeTasks: <SidebarActiveTask>[],
    activeWorkflows: <SidebarActiveWorkflow>[],
    showChannels: true,
    tasksEnabled: false,
    activeSessionId: null,
  );
  const navItems = <NavItem>[(label: 'Tasks', href: '/tasks', active: true, navGroup: 'system', icon: 'tasks')];

  test('renders draft start action', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Draft task',
        'status': 'draft',
        'type': 'research',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, contains('hx-post="/tasks/task-1/start"'));
    expect(html, contains('hx-select="#tasks-content"'));
    expect(html, isNot(contains('data-task-start')));
    expect(html, contains('Start Task'));
    expect(html, contains('data-controller="dc-tasks"'));
    expect(html, contains('No artifacts yet'));
    expect(html, isNot(contains('\ud83d\uddc3')));
    // One claw mark, and it is the sidebar's brand lockup — neither column
    // empty state carries one of its own.
    expect(RegExp('class="claw-mark"').allMatches(html), hasLength(1));
    // Both column empties come from the shared fragment, so neither carries a
    // page-local emoji of its own any more.
    expect(html, isNot(contains('\ud83d\udcac')));
    expect(html, contains('Session not started'));
    expect(html, isNot(contains('Research task')));
  });

  test('task action forms carry the active list query', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Review task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      actionQuery: 'status=review&include=workflow',
    );

    expect(html, contains('action="/tasks/task-1/review?status=review&amp;include=workflow"'));
    expect(html, contains('hx-post="/tasks/task-1/review?status=review&amp;include=workflow"'));
  });

  test('renders session turn status with tasks controller mount', () {
    final html = sessionInfoTemplate(
      sessionId: 'session-123',
      sessionTitle: 'Session',
      messageCount: 2,
      sidebarData: emptySidebar,
      navItems: navItems,
      turnStatus: const {
        'session_id': 'session-123',
        'turn_id': 'turn-456',
        'state': 'waiting',
        'wait_reason': 'session_lock',
        'can_cancel': true,
      },
    );

    expect(html, contains('data-controller="dc-tasks"'));
    expect(html, contains('data-turn-status-session-id="session-123"'));
    expect(html, contains('data-turn-status-turn-id="turn-456"'));
    expect(html, contains('data-turn-cancel'));
    expect(html, contains('data-session-id="session-123"'));
    expect(html, contains('data-turn-id="turn-456"'));
  });

  test('renders session token usage as canonical metric cards', () {
    final html = sessionInfoTemplate(
      sessionId: 'session-123',
      sessionTitle: 'Session',
      messageCount: 2,
      sidebarData: emptySidebar,
      navItems: navItems,
      inputTokens: 1500,
      outputTokens: 500,
    );

    expect(html, contains('class="content-area print-in"'));
    expect(html, contains('class="content-inner"'));
    expect(html, contains('card-metric--info'));
    expect(html, contains('card-metric--accent'));
    expect(html, contains('metric-label">Total</div>'));
    expect(html, isNot(contains('token-stat')));
  });

  test('scopes the Codex fresh-input tooltip to the Input metric label', () {
    final html = sessionInfoTemplate(
      sessionId: 'session-123',
      sessionTitle: 'Session',
      messageCount: 2,
      sidebarData: emptySidebar,
      navItems: navItems,
      provider: 'codex',
      inputTokens: 1500,
      outputTokens: 500,
    );
    const tooltip = 'Fresh input tokens only. Cached input is tracked separately below.';

    expect(html, contains('class="metric-label" title="$tooltip">Input (fresh)</div>'));
    expect(RegExp(RegExp.escape(tooltip)).allMatches(html), hasLength(1));
  });

  test('session info consumes shared relative Created rendering', () {
    const createdAt = '2026-04-15T10:00:00.000';
    final html = sessionInfoTemplate(
      sessionId: 'session-123',
      sessionTitle: 'Session',
      messageCount: 2,
      sidebarData: emptySidebar,
      navItems: navItems,
      createdAt: createdAt,
    );

    // The rendering is S16's shared helper, not a formatter of this surface's own.
    final expected = formatRelativeTime(DateTime.parse(createdAt));
    expect(html, contains('title="$createdAt"'));
    expect(html, contains('>$expected<'));
    expect(html, isNot(contains('>$createdAt<')), reason: 'the raw ISO instant reached the surface');
  });

  test('session info renders the shared page header and three token cards on one row', () {
    final html = sessionInfoTemplate(
      sessionId: 'session-123',
      sessionTitle: 'My Session',
      messageCount: 2,
      sidebarData: emptySidebar,
      navItems: navItems,
      inputTokens: 1500,
      outputTokens: 500,
    );

    expect(html, contains('<header class="pagehead">'));
    expect(html, contains('My Session'));
    expect(html, contains('class="page-subtitle t-body"'));
    expect(html, isNot(contains('info-title')));
    expect(html, isNot(contains('info-subtitle')));
    // The topbar keeps the page's only <h1>.
    expect(RegExp('<h1').allMatches(html), hasLength(1));
    for (final section in ['Token Usage', 'Session Details']) {
      expect(html, contains('<h2 class="section-title">$section</h2>'));
    }
    expect(html, contains('class="token-grid"'));
    expect(RegExp('class="card card-metric').allMatches(html), hasLength(3));
    // Session info is on the 900px list – it must not pick up the wide modifier.
    expect(html, contains('class="content-inner"'));
    expect(html, isNot(contains('content-inner--wide')));
  });

  test('session info shows the canonical absent treatment for unrecorded token counts', () {
    final html = sessionInfoTemplate(
      sessionId: 'session-123',
      sessionTitle: 'Session',
      messageCount: 0,
      sidebarData: emptySidebar,
      navItems: navItems,
    );

    expect(RegExp('metric-value t-metric value-absent').allMatches(html), hasLength(3));
    // Emitted empty, so canon's .value-absent:empty::before supplies the dash.
    expect(html, contains('value-absent"></div>'));
    expect(html, isNot(contains('—')), reason: 'a hardcoded em dash stands in for the absent treatment');

    // A recorded zero is a value, not an absence.
    final zeroed = sessionInfoTemplate(
      sessionId: 'session-123',
      sessionTitle: 'Session',
      messageCount: 0,
      sidebarData: emptySidebar,
      navItems: navItems,
      inputTokens: 0,
      outputTokens: 0,
    );
    expect(RegExp('metric-value t-metric value-absent').allMatches(zeroed), hasLength(1));
    expect(zeroed, contains('>0</div>'));
  });

  test('renders provider badge in the task meta grid', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Provider-aware task',
        'status': 'review',
        'provider': 'codex',
        'providerLabel': 'Codex',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, contains('Provider'));
    expect(html, contains('provider-badge-codex'));
    expect(html, contains('Codex'));
  });

  test('renders structured diff html when provided', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Review task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [
        {
          'name': 'diff.json',
          'kind': 'diff',
          'content': '{}',
          'renderedHtml': '<section class="task-diff-file"><strong>lib/main.dart</strong></section>',
        },
      ],
    );

    expect(html, contains('task-diff-file'));
    expect(html, contains('lib/main.dart'));
    expect(html, contains('terminal-frame'));
    expect(html, contains('terminal-frame-dots'));
    expect(html, contains('diff.json'));
  });

  test('frames raw artifacts with their filename title', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Data task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [
        {'name': 'result.json', 'kind': 'data', 'content': '{"ok":true}'},
      ],
    );

    expect(html, contains('terminal-frame-body'));
    expect(html, contains('task-artifact-raw'));
    expect(html, contains('result.json'));
  });

  test('uses the artifact kind when a framed artifact has no filename', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Untitled artifact',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [
        {'kind': 'data', 'content': '{"ok":true}'},
      ],
    );

    expect(html, contains('>Data<'));
  });

  test('uses native details for the initially collapsed push-back comment', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Review task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, contains('<details class="pushback-comment">'));
    expect(html, contains('<summary class="btn btn-pushback">Push Back</summary>'));
    expect(html, isNot(contains('pushback-comment" style=')));
    expect(html, contains('name="action" value="push_back"'));
    expect(html, isNot(contains('data-action="push_back"')));
  });

  test('renders token summary card when traceCount > 0', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Traced task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      tokenSummary: const {
        'traceCount': 3,
        'totalTokens': 15500,
        'totalInputTokens': 12000,
        'totalOutputTokens': 3500,
        'totalCacheReadTokens': 0,
        'totalCacheWriteTokens': 0,
        'totalDurationMs': 45000,
        'totalToolCalls': 24,
      },
    );

    expect(html, contains('task-token-summary'));
    expect(html, contains('Total Tokens'));
    expect(html, contains('15,500'));
    expect(html, contains('12,000'));
    expect(html, contains('3,500'));
    expect(html, contains('45s'));
    expect(html, contains('24'));
    expect(html, contains('Turns'));
    expect(html, contains('>3<'));
  });

  test('hides token summary card when traceCount is 0', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Untraced task',
        'status': 'draft',
        'description': 'Not started',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      tokenSummary: const {
        'traceCount': 0,
        'totalTokens': 0,
        'totalInputTokens': 0,
        'totalOutputTokens': 0,
        'totalCacheReadTokens': 0,
        'totalCacheWriteTokens': 0,
        'totalDurationMs': 0,
        'totalToolCalls': 0,
      },
    );

    expect(html, isNot(contains('task-token-summary')));
  });

  test('hides cache row when no cache tokens', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'No cache task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      tokenSummary: const {
        'traceCount': 2,
        'totalTokens': 1000,
        'totalInputTokens': 800,
        'totalOutputTokens': 200,
        'totalCacheReadTokens': 0,
        'totalCacheWriteTokens': 0,
        'totalDurationMs': 10000,
        'totalToolCalls': 5,
      },
    );

    expect(html, contains('task-token-summary'));
    expect(html, isNot(contains('Cache')));
  });

  test('injects timelineHtml when provided', () {
    const sentinel = '<div class="task-timeline" data-test-sentinel="1"></div>';
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Timeline task',
        'status': 'running',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      timelineHtml: sentinel,
    );

    expect(html, contains(sentinel));
  });

  test('renders a scan bar and one activity claw without a token budget', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Running task',
        'status': 'running',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      timelineHtml: '<div class="task-timeline"></div>',
    );

    expect(html, contains('class="scan-bar"'));
    expect(html, isNot(contains('budget-bar-fill')));
    expect(RegExp('class="claw-loader"').allMatches(html), hasLength(1));
    expect(RegExp('class="claw-mark"').allMatches(html), hasLength(1));
  });

  test('renders bound channels section when bindings are present', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Bound task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      bindings: const [
        {'channelType': 'googlechat', 'threadId': 'spaces/AAAA/threads/BBBB'},
        {'channelType': 'whatsapp', 'threadId': 'group@g.us'},
      ],
    );

    expect(html, contains('Bound Channels'));
    expect(html, contains('Google Chat'));
    expect(html, contains('WhatsApp'));
    expect(html, contains('spaces/AAAA/threads/BBBB'));
    expect(html, contains('group@g.us'));
  });

  test('omits bound channels section when bindings are absent', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Unbound task',
        'status': 'review',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, isNot(contains('Bound Channels')));
  });

  test('omits timeline section when timelineHtml is null', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'No timeline task',
        'status': 'draft',
        'description': 'Do work',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
    );

    expect(html, isNot(contains('task-timeline')));
  });

  test('renders turn wait status with cancel affordance when cancellable', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Running task',
        'status': 'running',
        'description': 'Do work',
        'sessionId': 'session-123',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      messagesHtml: '<div>message</div>',
      turnStatus: const {
        'session_id': 'session-123',
        'turn_id': 'turn-456',
        'state': 'stuck',
        'wait_reason': 'session_lock',
        'waiting_since': '2026-03-10T10:00:00.000Z',
        'stuck_since': '2026-03-10T10:02:00.000Z',
        'global_timeout_at': '2026-03-10T10:05:00.000Z',
        'can_cancel': true,
      },
    );

    expect(html, contains('data-turn-status-session-id="session-123"'));
    expect(html, contains('data-turn-status-turn-id="turn-456"'));
    expect(html, contains('data-turn-status-state'));
    expect(html, contains('Stuck'));
    expect(html, contains('session lock'));
    expect(html, contains('data-turn-cancel'));
    expect(html, contains('Cancel Turn'));
  });

  test('keeps an inert turn-status mount for idle sessions', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Done task',
        'status': 'accepted',
        'description': 'Do work',
        'sessionId': 'session-123',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      messagesHtml: '<div>message</div>',
      turnStatus: const {'session_id': 'session-123', 'state': 'idle', 'can_cancel': false},
    );

    expect(html, contains('class="turn-status-panel" hidden=""'));
    expect(html, contains('data-turn-status-session-id="session-123"'));
    expect(html, contains('data-turn-cancel'));
    expect(html, contains('disabled="disabled"'));
  });

  test('does not render cached terminal turn status as an active panel', () {
    final html = taskDetailPageTemplate(
      sidebarData: emptySidebar,
      navItems: navItems,
      task: const {
        'id': 'task-1',
        'title': 'Done task',
        'status': 'accepted',
        'description': 'Do work',
        'sessionId': 'session-123',
        'createdAt': '2026-03-10T10:00:00Z',
      },
      artifacts: const [],
      messagesHtml: '<div>message</div>',
      turnStatus: const {
        'session_id': 'session-123',
        'turn_id': 'turn-completed',
        'state': 'completed',
        'can_cancel': false,
      },
    );

    expect(html, contains('class="turn-status-panel" hidden=""'));
    expect(html, contains('data-turn-status-session-id="session-123"'));
    expect(html, contains('data-turn-cancel'));
    expect(html, contains('disabled="disabled"'));
  });
}
