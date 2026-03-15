import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../behavior/heartbeat_scheduler.dart';
import '../runtime_config.dart';
import '../scheduling/schedule_service.dart';
import '../workspace/workspace_git_sync.dart';
import 'api_helpers.dart';

/// Toggle API endpoints for runtime service control.
///
/// All toggles are ephemeral — state resets on process restart.
Router configRoutes({
  required RuntimeConfig runtimeConfig,
  HeartbeatScheduler? heartbeat,
  ScheduleService? scheduleService,
  WorkspaceGitSync? gitSync,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> scheduledJobs = const [],
}) {
  final router = Router();

  // POST /api/settings/heartbeat/toggle
  router.post('/api/settings/heartbeat/toggle', (Request request) async {
    if (heartbeat == null) {
      return errorResponse(404, 'NOT_AVAILABLE', 'Heartbeat service not configured');
    }

    final body = await _parseBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid request body');
    }

    final enabled = body['enabled'];
    if (enabled is! bool) {
      return errorResponse(400, 'INVALID_INPUT', '"enabled" must be a boolean');
    }

    if (enabled) {
      heartbeat.start();
    } else {
      heartbeat.stop();
    }
    runtimeConfig.heartbeatEnabled = enabled;

    return jsonResponse(200, {'enabled': enabled, 'intervalMinutes': heartbeatIntervalMinutes});
  });

  // POST /api/settings/git-sync/toggle
  router.post('/api/settings/git-sync/toggle', (Request request) async {
    if (gitSync == null) {
      return errorResponse(404, 'NOT_AVAILABLE', 'Git sync not configured');
    }

    final body = await _parseBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid request body');
    }

    final enabled = body['enabled'];
    final pushEnabled = body['pushEnabled'];

    if (enabled != null) {
      if (enabled is! bool) {
        return errorResponse(400, 'INVALID_INPUT', '"enabled" must be a boolean');
      }
      runtimeConfig.gitSyncEnabled = enabled;
    }
    if (pushEnabled != null) {
      if (pushEnabled is! bool) {
        return errorResponse(400, 'INVALID_INPUT', '"pushEnabled" must be a boolean');
      }
      runtimeConfig.gitSyncPushEnabled = pushEnabled;
      gitSync.pushEnabled = pushEnabled;
    }

    return jsonResponse(200, {
      'enabled': runtimeConfig.gitSyncEnabled,
      'pushEnabled': runtimeConfig.gitSyncPushEnabled,
    });
  });

  // POST /api/scheduling/jobs/<name>/toggle
  router.post('/api/scheduling/jobs/<name>/toggle', (Request request, String name) async {
    if (scheduleService == null) {
      return errorResponse(404, 'NOT_AVAILABLE', 'Schedule service not configured');
    }

    // Find job in configured jobs list
    final jobExists = scheduledJobs.any((j) => j['name'] == name);
    if (!jobExists) {
      return errorResponse(404, 'NOT_FOUND', 'Job "$name" not found');
    }

    final body = await _parseBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid request body');
    }

    final status = body['status'];
    if (status != 'active' && status != 'paused') {
      return errorResponse(400, 'INVALID_INPUT', '"status" must be "active" or "paused"');
    }

    if (status == 'paused') {
      scheduleService.pauseJob(name);
    } else {
      scheduleService.resumeJob(name);
    }

    // Update display map for UI consistency (stays in sync with service state).
    for (final job in scheduledJobs) {
      if (job['name'] == name) {
        job['status'] = status;
        break;
      }
    }

    return jsonResponse(200, {'name': name, 'status': status});
  });

  // GET /api/settings/runtime
  router.get('/api/settings/runtime', (Request request) async {
    final jobStatuses = scheduledJobs
        .map(
          (j) => {
            'name': j['name']?.toString() ?? '',
            'status': j['status']?.toString() ?? 'active',
            'schedule': j['schedule']?.toString() ?? '',
          },
        )
        .toList();

    final result = {
      ...runtimeConfig.toJson(),
      'heartbeat': {'enabled': runtimeConfig.heartbeatEnabled, 'intervalMinutes': heartbeatIntervalMinutes},
      'jobs': jobStatuses,
    };

    return jsonResponse(200, result);
  });

  return router;
}

/// Parses request body as JSON or form-encoded data.
///
/// Returns null only on malformed JSON (not on empty body).
/// Form-encoded `"true"`/`"false"` strings are coerced to [bool].
Future<Map<String, dynamic>?> _parseBody(Request request) async {
  final ct = request.headers['content-type'] ?? '';
  final body = await request.readAsString();

  if (ct.startsWith('application/json')) {
    if (body.isEmpty) return {};
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic>) return parsed;
      return null;
    } catch (_) {
      return null;
    }
  }

  // Default: form-encoded (HTMX sends application/x-www-form-urlencoded)
  return Uri.splitQueryString(body).map((k, v) => MapEntry(k, _coerceBool(v)));
}

dynamic _coerceBool(String v) {
  if (v == 'true') return true;
  if (v == 'false') return false;
  return v;
}
