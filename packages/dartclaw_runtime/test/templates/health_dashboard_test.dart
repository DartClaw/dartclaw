import 'package:dartclaw_runtime/src/audit/audit_log_reader.dart';
import 'package:dartclaw_runtime/src/templates/health_dashboard.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

SidebarData _emptySidebar() => (
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

const _emptyNavItems = <NavItem>[];

String _render({String status = 'healthy', Map<String, dynamic>? pubsubHealth}) => healthDashboardTemplate(
  status: status,
  uptimeSeconds: 3600,
  workerState: 'idle',
  sessionCount: 5,
  dbSizeBytes: 1024,
  totalArtifactDiskBytes: 0,
  version: '0.11.0',
  sidebarData: _emptySidebar(),
  navItems: _emptyNavItems,
  auditPage: AuditPage.empty,
  pubsubHealth: pubsubHealth,
);

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('health dashboard Pub/Sub card', () {
    test('renders canonical health status variants and metric cards', () {
      for (final (status, featured, badge, dot) in [
        ('healthy', 'card-featured-accent', 'status-badge-success', 'status-dot--live'),
        ('degraded', 'card-featured-warning', 'status-badge-warning', 'status-dot--warning'),
        ('unavailable', 'card-featured-error', 'status-badge-error', 'status-dot--error'),
      ]) {
        final html = _render(status: status);

        expect(html, contains(featured));
        expect(html, contains(badge));
        expect(html, contains(dot));
        expect(html, contains('content-area'));
        expect(html, contains('content-inner'));
        expect(RegExp('class="card card-metric').allMatches(html), hasLength(4));
        expect(html, isNot(contains('status-hero')));
        expect(html, isNot(contains('status-indicator')));
        expect(html, isNot(contains('status-label')));
      }
    });

    test('renders Pub/Sub card when pubsubHealth provided', () {
      final html = _render(
        pubsubHealth: {
          'status': 'healthy',
          'enabled': true,
          'last_successful_pull': '2026-03-20T10:30:00.000Z',
          'consecutive_errors': 0,
          'active_subscriptions': 3,
        },
      );

      expect(html, contains('Pub/Sub'));
      expect(html, contains('healthy'));
      expect(html, contains('3 active'));
      expect(html, contains('status-badge-success'));
    });

    test('info cards emit canon card anatomy with a footer status badge', () {
      final html = _render();

      // The Worker card is the first infoCard; its anatomy must run
      // header -> body -> footer, with the badge in the footer.
      final header = html.indexOf('<div class="card-header">');
      final body = html.indexOf('<div class="card-body">', header);
      final footer = html.indexOf('<div class="card-footer">', body);
      expect(header, greaterThan(-1), reason: 'infoCard must emit .card-header');
      expect(body, greaterThan(header), reason: '.card-body must follow .card-header');
      expect(footer, greaterThan(body), reason: '.card-footer must follow .card-body');

      // The badge is a canon .status-badge in the footer, not the retired .card-badge.
      expect(html.substring(footer), contains('class="status-badge status-badge-'));
      final firstCardBadge = html.indexOf('card-badge');
      expect(
        firstCardBadge == -1 || firstCardBadge > footer,
        isTrue,
        reason: 'infoCard must not emit the retired .card-badge',
      );

      // Rows live inside the body, so their spacing comes from .card-body > .card-row.
      expect(html.substring(body, footer), contains('class="card-row"'));
    });

    test('omits Pub/Sub card when pubsubHealth is null', () {
      final html = _render();
      // "Pub/Sub" card title should not be present
      expect(html, isNot(contains('>Pub/Sub<')));
    });

    test('renders disabled state when pubsub not configured', () {
      final html = _render(pubsubHealth: {'status': 'disabled', 'enabled': false});

      expect(html, contains('Pub/Sub'));
      expect(html, contains('Not configured'));
      expect(html, contains('status-badge-muted'));
      expect(html, contains('off'));
    });

    test('renders degraded badge class when status is degraded', () {
      final html = _render(
        pubsubHealth: {'status': 'degraded', 'enabled': true, 'consecutive_errors': 7, 'active_subscriptions': 2},
      );

      expect(html, contains('status-badge-warning'));
      expect(html, contains('degraded'));
    });

    test('renders unavailable badge class when status is unavailable', () {
      final html = _render(pubsubHealth: {'status': 'unavailable', 'enabled': true, 'active_subscriptions': 0});

      expect(html, contains('status-badge-error'));
      expect(html, contains('unavailable'));
    });

    test('renders error count when errors > 0', () {
      final html = _render(
        pubsubHealth: {'status': 'degraded', 'enabled': true, 'consecutive_errors': 7, 'active_subscriptions': 2},
      );

      expect(html, contains('7 consecutive'));
    });

    test('does not render error row when errors are 0', () {
      final html = _render(
        pubsubHealth: {
          'status': 'healthy',
          'enabled': true,
          'last_successful_pull': '2026-03-20T10:30:00.000Z',
          'consecutive_errors': 0,
          'active_subscriptions': 3,
        },
      );

      expect(html, isNot(contains('consecutive')));
    });

    test('renders "never" when last_successful_pull is absent', () {
      final html = _render(pubsubHealth: {'status': 'unavailable', 'enabled': true, 'active_subscriptions': 0});

      expect(html, contains('never'));
    });

    test('renders an absolute short date for a long-past last_successful_pull', () {
      // Past 30 days the shared formatter rolls over from "Nd ago" to a date:
      // "2235d ago" is a subtraction problem, not something a reader can place.
      final html = _render(
        pubsubHealth: {
          'status': 'healthy',
          'enabled': true,
          'last_successful_pull': '2020-01-01T00:00:00.000Z',
          'consecutive_errors': 0,
          'active_subscriptions': 1,
        },
      );

      expect(html, contains('1 Jan 2020'));
      expect(html, isNot(contains('ago')));
    });

    test('renders Pub/Sub card alongside the service cards', () {
      final html = _render(pubsubHealth: {'status': 'healthy', 'enabled': true, 'active_subscriptions': 1});

      expect(html, contains('Storage'));
      expect(html, contains('Pub/Sub'));
    });
  });

  group('health dashboard composition', () {
    test('the KPI row is the first content under the topbar, ahead of the services grid', () {
      final html = _render();

      final inner = html.indexOf('class="content-inner content-inner--wide"');
      final metrics = html.indexOf('class="metrics-grid metrics-grid-4"', inner);
      final hero = html.indexOf('card-featured-accent', inner);
      final services = html.indexOf('<h2 class="section-title">Services</h2>', inner);

      expect(inner, greaterThan(-1), reason: 'health did not take the wide container');
      expect(metrics, greaterThan(inner));
      expect(hero, greaterThan(metrics), reason: 'the status hero still precedes the KPI row');
      expect(services, greaterThan(metrics), reason: 'the services grid still precedes the KPI row');
      // No heading stands between the topbar and the numbers.
      expect(html.substring(inner, metrics), isNot(contains('<h2')));
    });

    test('page-section headings use the canonical title tier', () {
      final html = _render();

      expect(html, contains('<h2 class="section-title">Services</h2>'));
      expect(html, contains('<h2 class="section-title">Guard Activity</h2>'));
      expect(html, isNot(contains('class="section-label"')));
    });

    test('each measured fact appears exactly once', () {
      // Distinct fixture values so a bare substring cannot match a different
      // fact's digits: uptime 2h 3m, 7 sessions, 4 KB db, 9 KB artifacts.
      final html = healthDashboardTemplate(
        status: 'healthy',
        uptimeSeconds: 7380,
        workerState: 'idle',
        sessionCount: 7,
        dbSizeBytes: 4096,
        totalArtifactDiskBytes: 9216,
        version: '0.11.0',
        sidebarData: _emptySidebar(),
        navItems: _emptyNavItems,
        auditPage: AuditPage.empty,
      );

      // Each fact is counted inside its own tile, so the assertion cannot pass
      // by matching a digit that belongs to another fact.
      for (final (label, value) in [('Uptime', '2h 3m'), ('Sessions', '7'), ('DB Size', '4 KB')]) {
        final tiles = RegExp(
          '<div class="metric-value t-metric"[^>]*>([^<]*)</div>\\s*<div class="metric-label"[^>]*>$label</div>',
        ).allMatches(html).toList();
        expect(tiles, hasLength(1), reason: '$label is not exactly one tile');
        expect(tiles.single.group(1), value);
        expect(RegExp('>${RegExp.escape(value)}<').allMatches(html), hasLength(1), reason: '$label appears twice');
      }
    });

    test('no row asserts a state the app never measured', () {
      final html = _render();

      for (final invented in ['claude binary', 'FTS5 Index', 'file-based', 'Search DB']) {
        expect(html, isNot(contains(invented)), reason: '$invented is a hardcoded constant, not a probe');
      }
    });

    test('worker state carries a variant its row can actually paint', () {
      // The row paints only states the worker vocabulary can produce, plus the
      // `unknown` the status payload substitutes for an absent worker.
      for (final (state, expected) in [
        ('idle', 'text-success'),
        ('busy', 'text-muted'),
        ('crashed', 'text-error'),
        ('stopped', 'text-muted'),
        ('unknown', 'text-muted'),
      ]) {
        final html = healthDashboardTemplate(
          status: 'healthy',
          uptimeSeconds: 60,
          workerState: state,
          sessionCount: 1,
          dbSizeBytes: 10,
          totalArtifactDiskBytes: 0,
          version: '0.1.0',
          sidebarData: _emptySidebar(),
          navItems: _emptyNavItems,
        );
        expect(html, contains('class="card-row-value $expected"'), reason: 'worker $state');
      }
    });

    test('an unreported worker state renders the absent treatment, not a blank row', () {
      final html = healthDashboardTemplate(
        status: 'healthy',
        uptimeSeconds: 60,
        workerState: '',
        sessionCount: 1,
        dbSizeBytes: 10,
        totalArtifactDiskBytes: 0,
        version: '0.1.0',
        sidebarData: _emptySidebar(),
        navItems: _emptyNavItems,
      );

      expect(html, contains('class="card-row-value value-absent"'));
    });

    test('the status refresh is scoped so it cannot reset the self-polling audit', () {
      final html = _render();

      final live = html.indexOf('id="health-live"');
      final liveEnd = html.indexOf('<h2 class="section-title">Guard Activity</h2>');
      final audit = html.indexOf('id="audit-table-container"');

      expect(live, greaterThan(-1));
      expect(html, contains('hx-select="#health-live"'));
      expect(html, isNot(contains('hx-select=".content-inner"')));
      expect(
        audit,
        greaterThan(liveEnd),
        reason: 'a refresh of the status region would replace the audit and drop its filter, page and open row',
      );
      expect(liveEnd, greaterThan(live));
    });

    test('the refresh indicator is overlaid, not a placeholder above the content', () {
      final html = _render();

      expect(html, contains('<div id="health-loading" class="poll-skeleton htmx-indicator" aria-hidden="true">'));
      expect(html, contains('<div class="scan-bar"></div>'));
      expect(html, isNot(contains('skeleton skeleton-text')));
    });
  });
}
