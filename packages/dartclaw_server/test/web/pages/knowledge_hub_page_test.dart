import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/pages/knowledge_hub_page.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../../test_utils.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late Database searchDb;
  late Database taskDb;
  late MemoryService memory;
  late TemporalKnowledgeGraphService kg;

  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('knowledge_hub_page_test_');
    sessions = SessionService(baseDir: tempDir.path);
    searchDb = sqlite3.openInMemory();
    taskDb = sqlite3.openInMemory();
    memory = MemoryService(searchDb);
    kg = TemporalKnowledgeGraphService(taskDb);
    _writeFile(tempDir, 'wiki/onboarding.md', 'Merge queue onboarding keeps source links.');
    _writeFile(tempDir, 'inbox/merge-note.md', 'Merge source landed in the inbox.');
    searchDb.execute('INSERT INTO memory_chunks (text, source, category, created_at, locator) VALUES (?, ?, ?, ?, ?)', [
      'Merge memory keeps durable context.',
      'MEMORY.md',
      'build',
      DateTime(2026).toIso8601String(),
      'MEMORY.md',
    ]);
    kg.addFact(
      entity: 'Merge queue',
      predicate: 'policy',
      value: 'requires green checks',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'wiki/onboarding.md',
    );
  });

  tearDown(() {
    searchDb.close();
    taskDb.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('S01 and S03 render all layer badges, source links, and shared attribution', () async {
    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?q=merge');

    expect(html, contains('READ-ONLY'));
    expect(html, contains('layer-badge--wiki'));
    expect(html, contains('layer-badge--kg'));
    expect(html, contains('layer-badge--memory'));
    expect(html, contains('layer-badge--inbox'));
    expect(html, contains('href="/knowledge/wiki/wiki/onboarding.md"'));
    expect(html, contains('source-attribution'));
    expect(html, contains('citation-marker'));
  });

  test('S01 renders canonical memory roles as distinct operator labels', () async {
    final page = KnowledgeHubPage(
      hubGetter: () => knowledgeHubServiceForWorkspace(
        workspaceDir: tempDir.path,
        memory: memory,
        kg: kg,
        searchBackend: const _RoleSearchBackend(),
      ),
    );

    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?q=role', page: page);

    for (final label in ['CURATED', 'ARCHIVE', 'OBSERVATION', 'LEARNING']) {
      expect(html, contains('>$label<'), reason: label);
    }
  });

  test('S02 scopes the KG chip to KG results only', () async {
    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?q=merge&layer=kg');

    expect(html, contains('layer-badge--kg'));
    expect(html, isNot(contains('layer-badge--wiki')));
    expect(html, isNot(contains('layer-badge--memory')));
    expect(html, isNot(contains('layer-badge--inbox')));
  });

  test('OC01 lists wiki content without a search query', () async {
    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?layer=wiki');

    expect(html, contains('layer-badge--wiki'));
    expect(html, contains('href="/knowledge/wiki/wiki/onboarding.md"'));
    expect(html, isNot(contains('No wiki pages yet.')));
  });

  test('S04 renders no write controls while keeping read-only search and attribution controls', () async {
    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?q=merge');
    final hubHtml = html.substring(html.indexOf('knowledge-hub-page'));

    expect(hubHtml, contains('method="get"'));
    expect(hubHtml, isNot(contains('method="post"')));
    expect(hubHtml.toLowerCase(), isNot(contains('delete')));
    expect(hubHtml.toLowerCase(), isNot(contains('save')));
    expect(hubHtml.toLowerCase(), isNot(contains('edit')));
    expect(hubHtml.toLowerCase(), isNot(contains('create')));
  });

  test('S05 renders inbox-specific empty state with search and summary still visible', () async {
    Directory('${tempDir.path}/inbox').deleteSync(recursive: true);

    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?layer=inbox');

    expect(html, contains('class="empty-state-title t-label">Inbox is clear<'));
    expect(html, contains('Captured items awaiting triage appear here.'));
    expect(html, contains('class="list-toolbar"'));
    expect(html, contains('class="form-input form-input--search"'));
    expect(html, contains('knowledge-summary-strip'));
  });

  test('S06 renders partial failure notice without returning 500', () async {
    final response = await _render(
      page: KnowledgeHubPage(
        hubGetter: () =>
            knowledgeHubServiceForWorkspace(workspaceDir: tempDir.path, memory: memory, kg: _ThrowingKg(taskDb)),
      ),
      path: '/knowledge?q=merge',
      sessions: sessions,
    );
    final html = await response.readAsString();

    expect(response.statusCode, 200);
    expect(html, contains('Partial results'));
    expect(html, contains('KG'));
    expect(html, contains('layer-badge--wiki'));
    expect(html, contains('layer-badge--memory'));
    expect(html, contains('layer-badge--inbox'));
  });

  test('S07 no-match search renders broaden query empty state', () async {
    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?q=zzznomatch');

    expect(html, contains('class="empty-state-title t-label">No results<'));
    expect(html, contains('Broaden it or switch layers.'));
    expect(html, isNot(contains('Merge memory keeps durable context.')));
  });

  test('unresolved sources are checked once and expose no authoritative title or link', () async {
    final resolver = _RecordingResolver();
    final page = KnowledgeHubPage(
      resolver: resolver,
      hubGetter: () => knowledgeHubServiceForWorkspace(
        workspaceDir: tempDir.path,
        memory: memory,
        kg: kg,
        searchBackend: const _UnresolvedSearchBackend(),
      ),
    );

    final html = await _renderHtml(tempDir, sessions, memory, kg, path: '/knowledge?q=unverified', page: page);

    expect(resolver.refs.map((ref) => ref.locator), {'00000000-0000-4000-8000-000000000001', 'wiki/private-source.md'});
    expect(resolver.refs, hasLength(2));
    expect(html, contains('private memory snippet'));
    expect(html, contains('private wiki snippet'));
    expect(html, contains('Unverified'));
    expect(html, isNot(contains('Private memory title')));
    expect(html, isNot(contains('Private Source')));
    expect(html, isNot(contains('00000000-0000-4000-8000-000000000001')));
    expect(html, isNot(contains('wiki/private-source.md')));
  });
}

Future<String> _renderHtml(
  Directory tempDir,
  SessionService sessions,
  MemoryService memory,
  TemporalKnowledgeGraphService kg, {
  String path = '/knowledge',
  KnowledgeHubPage? page,
}) async {
  final response = await _render(
    path: path,
    page:
        page ??
        KnowledgeHubPage(
          hubGetter: () => knowledgeHubServiceForWorkspace(workspaceDir: tempDir.path, memory: memory, kg: kg),
        ),
    sessions: sessions,
  );
  expect(response.statusCode, 200);
  return response.readAsString();
}

Future<Response> _render({required String path, required KnowledgeHubPage page, required SessionService sessions}) {
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

void _writeFile(Directory tempDir, String relativePath, String body) {
  final file = File('${tempDir.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(body);
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

final class _ThrowingKg extends TemporalKnowledgeGraphService {
  new(super.db);

  @override
  List<KnowledgeFact> allFacts({String? asOf, String? search, int? limit}) => throw StateError('boom');
}

final class _RoleSearchBackend implements SearchBackend {
  const new();

  @override
  Future<void> indexAfterWrite() async {}

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    const roles = ['topic', 'archive', 'observation', 'learning'];
    return MemorySearchOutcome(
      results: [
        for (var index = 0; index < roles.length; index++)
          MemorySearchResult.canonical(
            text: '${roles[index]} role result',
            source: roles[index],
            score: index.toDouble(),
            role: roles[index],
            provenance: 'test',
            locator: '00000000-0000-0000-0000-00000000000${index + 1}',
            entryId: '00000000-0000-0000-0000-00000000000${index + 1}',
            entryRevision: 1,
          ),
      ],
    );
  }
}

final class _UnresolvedSearchBackend implements SearchBackend {
  const new();

  @override
  Future<void> indexAfterWrite() async {}

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    return MemorySearchOutcome(
      results: [
        MemorySearchResult.canonical(
          text: 'private memory snippet',
          source: 'topic',
          category: 'Private memory title',
          score: 1,
          role: 'topic',
          provenance: 'test',
          locator: '00000000-0000-4000-8000-000000000001',
          entryId: '00000000-0000-4000-8000-000000000001',
          entryRevision: 1,
        ),
        const MemorySearchResult(
          text: 'private wiki snippet',
          source: 'wiki/private-source.md',
          score: 0,
          role: 'wiki',
          provenance: 'test',
          locator: 'wiki/private-source.md',
        ),
      ],
    );
  }
}

final class _RecordingResolver implements CitationSourceResolver {
  final refs = <SourceRef>[];

  @override
  Future<bool> resolves(SourceRef ref) async {
    refs.add(ref);
    return false;
  }
}
