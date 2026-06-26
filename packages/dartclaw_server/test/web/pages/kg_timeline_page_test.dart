import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/pages/kg_timeline_page.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late Database db;
  late TemporalKnowledgeGraphService kg;

  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('kg_timeline_page_test_');
    sessions = SessionService(baseDir: tempDir.path);
    db = sqlite3.openInMemory();
    kg = TemporalKnowledgeGraphService(db);
  });

  tearDown(() {
    db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('renders category groups ordered by validity windows', () async {
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'beta',
      validFrom: '2026-02-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/architecture.md',
    );
    kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite-wal',
      validFrom: '2026-03-01T00:00:00Z',
      source: 'wiki/architecture.md',
    );

    final html = await _renderHtml(KgTimelinePage(kgGetter: () => kg), sessions);

    expect(html.indexOf('architecture decisions'), lessThan(html.indexOf('project status')));
    expect(html.indexOf('2026-01-01T00:00:00.000Z'), lessThan(html.indexOf('2026-03-01T00:00:00.000Z')));
    expect(html, contains('valid_from'));
    expect(html, contains('valid_to'));
    expect(html, contains('ongoing'));
  });

  test('keeps superseded and contradicting facts visible', () async {
    final oldId = kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    kg.invalidate(id: oldId, invalidatedAt: '2026-02-01T00:00:00Z', reason: 'phase changed');
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'beta',
      validFrom: '2026-02-01T00:00:00Z',
      source: 'wiki/status.md',
    );
    kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/architecture.md',
    );
    kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'postgres',
      validFrom: '2026-01-02T00:00:00Z',
      source: 'inbox/architecture.md',
    );

    final html = await _renderHtml(KgTimelinePage(kgGetter: () => kg), sessions);

    expect(html, contains('alpha'));
    expect(html, contains('superseded'));
    expect(html, contains('sqlite'));
    expect(html, contains('postgres'));
    expect(html, contains('conflict cluster'));
    expect(RegExp(r'class="card kg-fact-card').allMatches(html), hasLength(4));
  });

  test('renders active-as-of and future-dated facts while now clears the query', () async {
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2025-08-01T00:00:00Z',
      validTo: '2026-01-15T00:00:00Z',
      source: 'wiki/status.md',
    );
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'beta',
      validFrom: '2026-01-15T00:00:00Z',
      source: 'wiki/status.md',
    );

    final html = await _renderHtml(
      KgTimelinePage(kgGetter: () => kg),
      sessions,
      path: '/knowledge/timeline?as_of=2025-09-01T00:00:00Z',
    );

    expect(html, contains('active-as-of'));
    expect(html, contains('not-yet-valid'));
    expect(html, contains('href="/knowledge/timeline">↺ now</a>'));
  });

  test('date-only as-of uses the KG UTC parser for active classification', () async {
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2025-09-01T00:00:00Z',
      source: 'wiki/status.md',
    );

    final html = await _renderHtml(
      KgTimelinePage(kgGetter: () => kg),
      sessions,
      path: '/knowledge/timeline?as_of=2025-09-01',
    );

    expect(html, contains('active-as-of'));
    expect(html, isNot(contains('not-yet-valid')));
  });

  test('future contradictory facts are not rendered as active conflicts in as-of view', () async {
    kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite',
      validFrom: '2026-01-15T00:00:00Z',
      source: 'wiki/architecture.md',
    );
    kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'postgres',
      validFrom: '2026-01-20T00:00:00Z',
      source: 'inbox/architecture.md',
    );

    final html = await _renderHtml(
      KgTimelinePage(kgGetter: () => kg),
      sessions,
      path: '/knowledge/timeline?as_of=2026-01-01T00:00:00Z',
    );

    expect(html, contains('not-yet-valid'));
    expect(html, isNot(contains('conflict cluster')));
  });

  test('historical resolved contradictions are rendered as conflicts in as-of view', () async {
    kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'sqlite',
      validFrom: '2026-01-15T00:00:00Z',
      source: 'wiki/architecture.md',
    );
    final postgresId = kg.addFact(
      entity: 'Architecture Decisions',
      predicate: 'database',
      value: 'postgres',
      validFrom: '2026-01-20T00:00:00Z',
      source: 'inbox/architecture.md',
    );
    kg.invalidate(id: postgresId, invalidatedAt: '2026-02-01T00:00:00Z', reason: 'decision reverted');

    final html = await _renderHtml(
      KgTimelinePage(kgGetter: () => kg),
      sessions,
      path: '/knowledge/timeline?as_of=2026-01-25T00:00:00Z',
    );

    expect(html, contains('sqlite'));
    expect(html, contains('postgres'));
    expect(RegExp('conflict cluster').allMatches(html), hasLength(2));
  });

  test('rejects invalid as-of timestamps without rendering fact cards', () async {
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/status.md',
    );

    final response = await _render(KgTimelinePage(kgGetter: () => kg), sessions, path: '/knowledge/timeline?as_of=bad');
    final html = await response.readAsString();

    expect(response.statusCode, 400);
    expect(html, contains('invalid as-of timestamp'));
    expect(html, isNot(contains('kg-fact-card')));
  });

  test('unknown category renders the empty state', () async {
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/status.md',
    );

    final html = await _renderHtml(
      KgTimelinePage(kgGetter: () => kg),
      sessions,
      path: '/knowledge/timeline?category=Architecture%20Decisions',
    );

    expect(html, contains('No facts recorded in this category yet.'));
    expect(html, isNot(contains('alpha')));
  });

  test('KG read failure renders an error and no fact cards', () async {
    final throwing = _ThrowingKg(db);

    final response = await _render(KgTimelinePage(kgGetter: () => throwing), sessions);
    final html = await response.readAsString();

    expect(response.statusCode, 500);
    expect(html, contains('Temporal KG query failed.'));
    expect(html, isNot(contains('kg-fact-card')));
  });

  test('renders shared attribution and unverified fallback', () async {
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/status.md',
    );

    final attributed = await _renderHtml(KgTimelinePage(kgGetter: () => kg), sessions);
    final unattributed = await _renderHtml(
      KgTimelinePage(kgGetter: () => kg, resolver: const _NeverResolver()),
      sessions,
    );

    expect(attributed, contains('source-attribution'));
    expect(attributed, contains('layer-badge--kg'));
    expect(attributed, contains('/knowledge/timeline#fact-1'));
    expect(unattributed, contains('Unverified'));
  });

  test('renders read-only controls only', () async {
    kg.addFact(
      entity: 'Project Status',
      predicate: 'phase',
      value: 'alpha',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/status.md',
    );

    final html = await _renderHtml(KgTimelinePage(kgGetter: () => kg), sessions);

    expect(html, isNot(contains('name="value"')));
    expect(html, isNot(contains('kg_add')));
    expect(html, isNot(contains('kg_invalidate')));
    expect(html, isNot(contains('method="post"')));
    expect(html, isNot(contains('Delete')));
  });
}

Future<Response> _render(KgTimelinePage page, SessionService sessions, {String path = '/knowledge/timeline'}) {
  return page.handler(
    Request('GET', Uri.parse('http://localhost$path')),
    PageContext(
      sessions: sessions,
      appDisplay: const AppDisplayParams(),
      sidebarData: () async => _emptySidebarData,
      restartBannerHtml: () => '',
      buildNavItems: ({required String activePage}) => const [],
    ),
  );
}

Future<String> _renderHtml(KgTimelinePage page, SessionService sessions, {String path = '/knowledge/timeline'}) async {
  final response = await _render(page, sessions, path: path);
  expect(response.statusCode, 200);
  return response.readAsString();
}

final _emptySidebarData = (
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

final class _NeverResolver implements CitationSourceResolver {
  const _NeverResolver();

  @override
  Future<bool> resolves(SourceRef ref) async => false;
}

final class _ThrowingKg extends TemporalKnowledgeGraphService {
  _ThrowingKg(super.db);

  @override
  List<KnowledgeFact> allFacts({String? asOf, String? search, int? limit}) => throw StateError('boom');
}
