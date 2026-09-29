import 'package:dartclaw_core/dartclaw_core.dart' show KvService;
import 'package:dartclaw_core/dartclaw_core.dart' show MemoryPruner;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../memory/memory_prune_service.dart';
import '../memory/memory_admin_service.dart';
import '../memory/memory_status_service.dart';
import '../memory/workspace_file_reader.dart';
import '../auth/request_auth_context.dart';
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
  MemoryAdminService? adminService,
}) {
  final router = Router();
  final workspaceFiles = WorkspaceFileReader(workspaceDir);
  final pruning = pruneService ?? MemoryPruneService(pruner: pruner, kvService: kvService);
  router.get('/api/memory/status', (Request request) async {
    if (request.url.hasQuery) return errorResponse(400, 'INVALID_INPUT', 'Memory status does not accept a selector');
    try {
      final status = await statusService.getStatus();
      return jsonResponse(200, status);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get memory status: $e');
    }
  });
  router.get('/api/memory/files/<name>', (Request request, String name) async {
    if (request.url.hasQuery) return errorResponse(400, 'INVALID_INPUT', 'Memory files do not accept a selector');
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
    if (request.url.hasQuery) return errorResponse(400, 'INVALID_INPUT', 'Memory prune does not accept a selector');
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
  Response denied() => errorResponse(403, 'FORBIDDEN', 'Memory administration requires owner access');
  Response unavailable() => errorResponse(404, 'CORPUS_UNAVAILABLE', 'Selected memory corpus is unavailable');
  Response failed() => errorResponse(503, 'MEMORY_UNAVAILABLE', 'Selected memory corpus could not be read');

  router.get('/api/memory/corpora', (Request request) async {
    if (!requestHasAdminAccess(request)) return denied();
    final service = adminService;
    if (service == null) return failed();
    try {
      return jsonResponse(200, await service.inventory());
    } on Object {
      return failed();
    }
  });
  router.get('/api/memory/entries', (Request request) async {
    if (!requestHasAdminAccess(request)) return denied();
    final service = adminService;
    if (service == null) return failed();
    final params = request.url.queryParameters;
    if (params.keys.any((key) => !const {'corpus', 'q', 'page'}.contains(key))) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid memory list request');
    }
    final page = int.tryParse(params['page'] ?? '1');
    if (page == null) return errorResponse(400, 'INVALID_INPUT', 'Invalid memory list request');
    try {
      return jsonResponse(200, await service.list(selector: params['corpus'], query: params['q'] ?? '', page: page));
    } on MemoryAdminUnavailable {
      return unavailable();
    } on ArgumentError {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid memory list request');
    } on Object {
      return failed();
    }
  });
  router.get('/api/memory/entries/<id>', (Request request, String rawId) async {
    if (!requestHasAdminAccess(request)) return denied();
    final service = adminService;
    if (service == null) return failed();
    final params = request.url.queryParameters;
    if (params.keys.any((key) => key != 'corpus')) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid memory detail request');
    }
    try {
      final result = await service.detail(selector: params['corpus'], id: decodePathSegment(rawId));
      return jsonResponse(result['state'] == 'notFound' ? 404 : 200, result);
    } on MemoryAdminUnavailable {
      return unavailable();
    } on Object {
      return failed();
    }
  });
  Future<Response> mutate(Request request, String rawId, String kind) async {
    if (!requestHasAdminAccess(request)) return denied();
    final service = adminService;
    if (service == null) return failed();
    final parsed = await readJsonObject(request);
    if (parsed.error != null) return parsed.error!;
    final body = parsed.value!;
    final allowed = kind == 'revise'
        ? const {'corpus', 'expectedCollectionRevision', 'expectedEntryRevision', 'topic', 'content', 'state'}
        : const {'corpus', 'expectedCollectionRevision', 'expectedEntryRevision', 'reason'};
    if (body.keys.any((key) => !allowed.contains(key)) ||
        body['corpus'] is! String ||
        body['expectedCollectionRevision'] is! int ||
        body['expectedEntryRevision'] is! int ||
        (kind == 'revise' && (body['topic'] is! String || body['content'] is! String || body['state'] is! String)) ||
        (kind == 'remove' && body['reason'] is! String)) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid memory mutation request');
    }
    try {
      final result = await service.apply(
        selector: body['corpus'] as String?,
        id: decodePathSegment(rawId),
        expectedCollectionRevision: body['expectedCollectionRevision'] as int,
        expectedEntryRevision: body['expectedEntryRevision'] as int,
        kind: kind,
        topic: body['topic'] as String?,
        content: body['content'] as String?,
        state: body['state'] as String?,
        reason: body['reason'] as String?,
      );
      final outcome = result['canonicalOutcome'];
      return jsonResponse(
        outcome == 'conflict'
            ? 409
            : outcome == 'rejected'
            ? 400
            : 200,
        result,
      );
    } on MemoryAdminUnavailable {
      return unavailable();
    } on ArgumentError {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid memory mutation request');
    } on Object {
      return failed();
    }
  }

  router.post('/api/memory/entries/<id>/revise', (Request request, String id) => mutate(request, id, 'revise'));
  router.post('/api/memory/entries/<id>/remove', (Request request, String id) => mutate(request, id, 'remove'));
  return router;
}
