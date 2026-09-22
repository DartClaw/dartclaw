import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryFullTextIndex;

Future<FullTextIndex> prepareMemoryIndex() async => InMemoryFullTextIndex();

Future<void> replaceMemoryCorpus(FullTextIndex index, CanonicalMemoryCorpus corpus, {String userId = 'owner'}) {
  return index.replaceAll(MemoryIndexProjection.documents(corpus), userId: userId);
}

Future<List<MemorySearchResult>> searchMemory(FullTextIndex index, String query, {String userId = 'owner'}) async {
  final results = await index.search(query, userId: userId);
  return results.map(MemoryIndexProjection.toSearchResult).toList(growable: false);
}
