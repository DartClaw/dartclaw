import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';

Future<SqliteFtsIndex> prepareMemoryIndex(Database database) async {
  final backend = SqliteBackend(database);
  await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
  return SqliteFtsIndex(backend, table: SqliteFtsTable.memoryChunks);
}

Future<void> replaceMemoryCorpus(FullTextIndex index, CanonicalMemoryCorpus corpus, {String userId = 'owner'}) {
  return index.replaceAll(MemoryIndexProjection.documents(corpus), userId: userId);
}

Future<List<MemorySearchResult>> searchMemory(FullTextIndex index, String query, {String userId = 'owner'}) async {
  final results = await index.search(query, userId: userId);
  return results.map(MemoryIndexProjection.toSearchResult).toList(growable: false);
}
