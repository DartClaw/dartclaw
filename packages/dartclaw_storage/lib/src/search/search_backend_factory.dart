import 'package:dartclaw_core/dartclaw_core.dart' show SearchBackend;

import '../storage/memory_service.dart';
import 'fts5_search_backend.dart';
import 'qmd_manager.dart';
import 'qmd_search_backend.dart';

/// Creates a [SearchBackend] based on the configured backend type.
SearchBackend createSearchBackend({
  required String backend,
  required MemoryService memoryService,
  QmdManager? qmdManager,
  String defaultDepth = 'standard',
}) {
  final fts5 = Fts5SearchBackend(memoryService: memoryService);

  if (backend == 'qmd' && qmdManager != null) {
    return QmdSearchBackend(
      manager: qmdManager,
      fallback: fts5,
      defaultDepth: SearchDepth.fromString(defaultDepth),
    );
  }

  return fts5;
}
