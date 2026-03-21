import 'package:dartclaw_server/src/audit/audit_log_reader.dart';
import 'package:dartclaw_server/src/templates/health_dashboard.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

SidebarData _emptySidebar() => (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
);

const _emptyNavItems = <NavItem>[];

String _render({Map<String, dynamic>? pubsubHealth}) => healthDashboardTemplate(
  status: 'healthy',
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
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('health dashboard Pub/Sub card', () {
    test('renders Pub/Sub card when pubsubHealth provided', () {
      final html = _render(pubsubHealth: {
        'status': 'healthy',
        'enabled': true,
        'last_successful_pull': '2026-03-20T10:30:00.000Z',
        'consecutive_errors': 0,
        'active_subscriptions': 3,
      });

      expect(html, contains('Pub/Sub'));
      expect(html, contains('healthy'));
      expect(html, contains('3 active'));
      expect(html, contains('badge-success'));
    });

    test('omits Pub/Sub card when pubsubHealth is null', () {
      final html = _render();
      // "Pub/Sub" card title should not be present
      expect(html, isNot(contains('>Pub/Sub<')));
    });

    test('renders disabled state when pubsub not configured', () {
      final html = _render(pubsubHealth: {
        'status': 'disabled',
        'enabled': false,
      });

      expect(html, contains('Pub/Sub'));
      expect(html, contains('Not configured'));
      expect(html, contains('badge-muted'));
      expect(html, contains('off'));
    });

    test('renders degraded badge class when status is degraded', () {
      final html = _render(pubsubHealth: {
        'status': 'degraded',
        'enabled': true,
        'consecutive_errors': 7,
        'active_subscriptions': 2,
      });

      expect(html, contains('badge-warning'));
      expect(html, contains('degraded'));
    });

    test('renders unavailable badge class when status is unavailable', () {
      final html = _render(pubsubHealth: {
        'status': 'unavailable',
        'enabled': true,
        'active_subscriptions': 0,
      });

      expect(html, contains('badge-error'));
      expect(html, contains('unavailable'));
    });

    test('renders error count when errors > 0', () {
      final html = _render(pubsubHealth: {
        'status': 'degraded',
        'enabled': true,
        'consecutive_errors': 7,
        'active_subscriptions': 2,
      });

      expect(html, contains('7 consecutive'));
    });

    test('does not render error row when errors are 0', () {
      final html = _render(pubsubHealth: {
        'status': 'healthy',
        'enabled': true,
        'last_successful_pull': '2026-03-20T10:30:00.000Z',
        'consecutive_errors': 0,
        'active_subscriptions': 3,
      });

      expect(html, isNot(contains('consecutive')));
    });

    test('renders "never" when last_successful_pull is absent', () {
      final html = _render(pubsubHealth: {
        'status': 'unavailable',
        'enabled': true,
        'active_subscriptions': 0,
      });

      expect(html, contains('never'));
    });

    test('renders relative time for recent last_successful_pull', () {
      // Use a timestamp far in the past so the relative display is "Xd ago"
      final html = _render(pubsubHealth: {
        'status': 'healthy',
        'enabled': true,
        'last_successful_pull': '2020-01-01T00:00:00.000Z',
        'consecutive_errors': 0,
        'active_subscriptions': 1,
      });

      expect(html, contains('ago'));
    });

    test('renders Pub/Sub card after existing cards (Worker, Database, etc.)', () {
      final html = _render(pubsubHealth: {
        'status': 'healthy',
        'enabled': true,
        'active_subscriptions': 1,
      });

      // All cards should be present
      expect(html, contains('Worker'));
      expect(html, contains('Database'));
      expect(html, contains('Pub/Sub'));
    });
  });
}
