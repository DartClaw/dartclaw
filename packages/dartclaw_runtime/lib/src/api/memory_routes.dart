import 'package:dartclaw_core/dartclaw_core.dart' show KvService;
import 'package:dartclaw_core/dartclaw_core.dart' show MemoryPruner;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../memory/memory_prune_service.dart';
import '../memory/memory_status_service.dart';
import '../memory/workspace_file_reader.dart';
import 'api_helpers.dart';

const _fileMap = {
  'memory': 'MEMORY.md',
  'errors': 'errors.md',
  'learnings': 'learnings.md',
  'archive': 'MEMORY.archive.md',
};

/// API routes for memory system status and file content.
Router memoryRoutes({
  required MemoryStatusService statusService,
  required String workspaceDir,
  MemoryPruner? pruner,
  KvService? kvService,
  MemoryPruneService? pruneService,
}) {
  final router = Router();
  final workspaceFiles = WorkspaceFileReader(workspaceDir);
  final pruning = pruneService ?? MemoryPruneService(pruner: pruner, kvService: kvService);
  router.get('/api/memory/status', (Request request) async {
    try {
      final status = await statusService.getStatus();
      return jsonResponse(200, status);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get memory status: $e');
    }
  });
  router.get('/api/memory/files/<name>', (Request request, String name) async {
    final relativePath = _fileMap[name];
    if (relativePath == null) {
      return errorResponse(404, 'NOT_FOUND', 'Unknown file name: "$name". Valid names: ${_fileMap.keys.join(', ')}');
    }

    try {
      final content = workspaceFiles.read(relativePath)?.content ?? '';
      return Response.ok(content, headers: {'content-type': 'text/plain; charset=utf-8'});
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read file: $e');
    }
  });
  router.post('/api/memory/prune', (Request request) async {
    try {
      final result = await pruning.prune();
      if (result == null) {
        return errorResponse(503, 'UNAVAILABLE', 'Memory pruner not configured');
      }
      return jsonResponse(200, memoryPruneJson(result));
    } catch (e) {
      return errorResponse(500, 'PRUNE_FAILED', 'Memory prune failed: $e');
    }
  });
  return router;
}
