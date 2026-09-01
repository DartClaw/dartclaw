import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../storage/memory_service.dart';
import 'composed_search_backend.dart';
import 'fts5_search_backend.dart';
import 'qmd_manager.dart';
import 'qmd_search_backend.dart';
import 'wiki_search_source.dart';

/// Creates a [SearchBackend] based on the configured backend type.
SearchBackend createSearchBackend({
  required String backend,
  required MemoryService memoryService,
  QmdManager? qmdManager,
  String defaultDepth = 'standard',
  String? workspaceDir,
  SearchIndexHealthProbe? indexHealthProbe,
}) {
  final wikiSearch = workspaceDir == null ? null : WikiSearchSource(workspaceDir: workspaceDir);
  final fts5 = Fts5SearchBackend(memoryService: memoryService);

  late final SearchBackend personal;
  if (backend == 'qmd' && qmdManager != null) {
    personal = QmdSearchBackend(
      manager: qmdManager,
      fallback: fts5,
      defaultDepth: SearchDepth.fromString(defaultDepth),
    );
  } else {
    personal = fts5;
  }

  return wikiSearch == null
      ? personal
      : ComposedSearchBackend(personal: personal, wiki: wikiSearch, indexHealthProbe: indexHealthProbe);
}
