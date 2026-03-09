import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show KvService;
import 'package:dartclaw_storage/dartclaw_storage.dart' show MemoryPruner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../memory/memory_status_service.dart';
import 'api_helpers.dart';

/// File name to workspace-relative path mapping for the file endpoint.
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
}) {
  final router = Router();

  // GET /api/memory/status
  router.get('/api/memory/status', (Request request) async {
    try {
      final status = await statusService.getStatus();
      return jsonResponse(200, status);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get memory status: $e');
    }
  });

  // GET /api/memory/files/<name>
  router.get('/api/memory/files/<name>', (Request request, String name) async {
    final relativePath = _fileMap[name];
    if (relativePath == null) {
      return errorResponse(404, 'NOT_FOUND', 'Unknown file name: "$name". Valid names: ${_fileMap.keys.join(', ')}');
    }

    final filePath = p.join(workspaceDir, relativePath);
    final file = File(filePath);

    if (!file.existsSync()) {
      return Response.ok('', headers: {'content-type': 'text/plain; charset=utf-8'});
    }

    try {
      final content = file.readAsStringSync();
      return Response.ok(content, headers: {'content-type': 'text/plain; charset=utf-8'});
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read file: $e');
    }
  });

  // POST /api/memory/prune
  router.post('/api/memory/prune', (Request request) async {
    final p = pruner;
    if (p == null) {
      return errorResponse(503, 'UNAVAILABLE', 'Memory pruner not configured');
    }

    try {
      final result = await p.prune();

      // Persist to prune history (same logic as cron runner in serve_command).
      final kv = kvService;
      if (kv != null) {
        await _appendPruneHistory(kv, result);
      }

      return jsonResponse(200, {
        'entriesArchived': result.entriesArchived,
        'duplicatesRemoved': result.duplicatesRemoved,
        'entriesRemaining': result.entriesRemaining,
        'finalSizeBytes': result.finalSizeBytes,
      });
    } catch (e) {
      return errorResponse(500, 'PRUNE_FAILED', 'Memory prune failed: $e');
    }
  });

  return router;
}

Future<void> _appendPruneHistory(KvService kv, ({int entriesArchived, int duplicatesRemoved, int entriesRemaining, int finalSizeBytes}) result) async {
  List<dynamic> history = [];
  try {
    final existing = await kv.get('prune_history');
    if (existing != null) {
      final parsed = jsonDecode(existing);
      if (parsed is List) history = parsed;
    }
  } catch (_) {}

  history.add({
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'entriesArchived': result.entriesArchived,
    'duplicatesRemoved': result.duplicatesRemoved,
    'entriesRemaining': result.entriesRemaining,
    'finalSizeBytes': result.finalSizeBytes,
  });

  // Trim to last 10.
  if (history.length > 10) {
    history = history.sublist(history.length - 10);
  }

  await kv.set('prune_history', jsonEncode(history));
}

