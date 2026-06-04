import 'package:dartclaw_core/dartclaw_core.dart' show SearchBackend;

import '../storage/memory_service.dart';
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
}) {
  final wikiSearch = workspaceDir == null ? null : WikiSearchSource(workspaceDir: workspaceDir);
  final fts5 = Fts5SearchBackend(memoryService: memoryService, wikiSearch: wikiSearch);

  if (backend == 'qmd' && qmdManager != null) {
    return QmdSearchBackend(
      manager: qmdManager,
      fallback: fts5,
      defaultDepth: SearchDepth.fromString(defaultDepth),
      wikiSearch: wikiSearch,
    );
  }

  return fts5;
}
