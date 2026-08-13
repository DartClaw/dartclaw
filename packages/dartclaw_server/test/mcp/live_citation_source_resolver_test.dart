import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('reopens role-discriminated canonical and native locators independently of search results', () async {
    final workspace = Directory.systemTemp.createTempSync('citation_resolver_');
    final searchDb = sqlite3.openInMemory();
    final taskDb = sqlite3.openInMemory();
    final corpus = MemoryCorpusService(workspaceDir: workspace.path);
    addTearDown(() async {
      await corpus.close();
      searchDb.close();
      taskDb.close();
      workspace.deleteSync(recursive: true);
    });
    final memory = MemoryService(searchDb);
    final wiki = WikiSearchSource(workspaceDir: workspace.path);
    final search = ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: wiki,
    );
    final handlers = createMemoryHandlers(
      memory: memory,
      memoryFile: MemoryFileService(baseDir: workspace.path, corpusService: corpus),
      corpusService: corpus,
      searchBackend: search,
    );

    final first = await _add(handlers, corpus, topic: 'projects', content: 'same source text');
    final second = await _add(handlers, corpus, topic: 'preferences', content: 'same source text');
    final learning = _decode(await handlers.onObserve({'text': 'canonical learning', 'role': 'learning'}));
    final learningId = learning['locator'] as String;
    final wikiFile = File(p.join(workspace.path, 'wiki', 'falcon.md'));
    wikiFile.parent.createSync(recursive: true);
    wikiFile.writeAsStringSync('Falcon wiki');
    final inboxFile = File(p.join(workspace.path, 'inbox', 'note.md'));
    inboxFile.parent.createSync(recursive: true);
    inboxFile.writeAsStringSync('Inbox note');
    final kg = TemporalKnowledgeGraphService(taskDb);
    final factId = kg.addFact(
      entity: 'Falcon',
      predicate: 'status',
      value: 'green',
      validFrom: '2026-08-12T00:00:00Z',
      source: 'wiki/falcon.md',
    );
    final resolver = LiveCitationSourceResolver(
      corpus: corpus,
      wiki: wiki,
      kg: kg,
      inbox: KnowledgeInboxReadService(workspaceDir: workspace.path),
    );

    expect(first, isNot(second));
    expect(await resolver.resolves(_ref(CitationLayer.memory, first, 'topic')), isTrue);
    expect(await resolver.resolves(_ref(CitationLayer.memory, second, 'topic')), isTrue);
    expect(await resolver.resolves(_ref(CitationLayer.memory, first, 'archive')), isFalse);
    expect(await resolver.resolves(_ref(CitationLayer.memory, 'MEMORY.md', 'topic')), isFalse);
    expect(await resolver.resolves(_ref(CitationLayer.memory, learningId, 'learning')), isTrue);
    expect(await resolver.resolves(_ref(CitationLayer.wiki, 'wiki/falcon.md', 'wiki')), isTrue);
    expect(await resolver.resolves(_ref(CitationLayer.wiki, 'wiki/falcon.md', 'topic')), isFalse);
    expect(await resolver.resolves(_ref(CitationLayer.wiki, 'wiki/falcon.md', null)), isFalse);
    expect(await resolver.resolves(_ref(CitationLayer.kg, '$factId', 'kg')), isTrue);
    expect(await resolver.resolves(_ref(CitationLayer.kg, '$factId', null)), isFalse);
    expect(await resolver.resolves(_ref(CitationLayer.inbox, 'inbox/note.md', 'knowledge-inbox')), isTrue);
    expect(await resolver.resolves(_ref(CitationLayer.inbox, 'inbox/note.md', null)), isFalse);
  });
}

Future<String> _add(
  MemoryHandlers handlers,
  MemoryCorpusService corpus, {
  required String topic,
  required String content,
}) async {
  final revision = (await corpus.readCorpus()).index.metadata.revision;
  final response = _decode(
    await handlers.onApply({
      'expectedRevision': revision,
      'operations': [
        {'kind': 'add', 'correlationId': topic, 'topic': topic, 'content': content},
      ],
    }),
  );
  return ((response['operations'] as Map<String, dynamic>)[topic] as Map<String, dynamic>)['entryId'] as String;
}

Map<String, dynamic> _decode(Map<String, dynamic> result) =>
    jsonDecode(((result['content'] as List).single as Map<String, dynamic>)['text'] as String) as Map<String, dynamic>;

SourceRef _ref(CitationLayer layer, String locator, String? role) =>
    SourceRef(layer: layer, locator: locator, label: locator, role: role);
