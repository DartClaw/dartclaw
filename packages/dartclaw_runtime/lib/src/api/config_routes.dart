import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../behavior/heartbeat_job.dart';
import '../config/runtime_toggle_applier.dart';
import '../runtime_config.dart';
import '../scheduling/schedule_service.dart';
import '../workspace/workspace_git_sync.dart';
import 'api_helpers.dart';

/// Toggle API endpoints for runtime service control.
///
/// All toggles are ephemeral — state resets on process restart.
Router configRoutes({
  required RuntimeConfig runtimeConfig,
  ScheduleService? scheduleService,
  WorkspaceGitSync? gitSync,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> scheduledJobs = const [],
}) {
  final router = Router();
  final toggles = RuntimeToggleApplier(
    runtimeConfig: runtimeConfig,
    scheduleService: scheduleService,
    gitSync: gitSync,
  );

  // POST /api/settings/heartbeat/toggle
  router.post('/api/settings/heartbeat/toggle', (Request request) async {
    // Pause/resume silently no-op for an unregistered id, so an SDK host that
    // wires a scheduler without the heartbeat must refuse rather than report 200
    // over a heartbeat that will never fire.
    if (scheduleService == null || !scheduleService.hasJob(heartbeatJobId)) {
      return errorResponse(404, 'NOT_AVAILABLE', 'Heartbeat service not configured');
    }

    final parsed = await _parseBody(request);
    if (parsed.error != null) return parsed.error!;
    final body = parsed.value!;

    final enabled = body['enabled'];
    if (enabled is! bool) {
      return errorResponse(400, 'INVALID_INPUT', '"enabled" must be a boolean');
    }

    toggles.setHeartbeatEnabled(enabled);

    return jsonResponse(200, {'enabled': enabled, 'intervalMinutes': heartbeatIntervalMinutes});
  });

  // POST /api/settings/git-sync/toggle
  router.post('/api/settings/git-sync/toggle', (Request request) async {
    if (gitSync == null) {
      return errorResponse(404, 'NOT_AVAILABLE', 'Git sync not configured');
    }

    final parsed = await _parseBody(request);
    if (parsed.error != null) return parsed.error!;
    final body = parsed.value!;

    final enabled = body['enabled'];
    final pushEnabled = body['pushEnabled'];

    if (enabled != null) {
      if (enabled is! bool) {
        return errorResponse(400, 'INVALID_INPUT', '"enabled" must be a boolean');
      }
      toggles.setGitSyncEnabled(enabled);
    }
    if (pushEnabled != null) {
      if (pushEnabled is! bool) {
        return errorResponse(400, 'INVALID_INPUT', '"pushEnabled" must be a boolean');
      }
      toggles.setGitSyncPushEnabled(pushEnabled);
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

    final parsed = await _parseBody(request);
    if (parsed.error != null) return parsed.error!;
    final body = parsed.value!;

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

  router.post('/api/scheduling/jobs/<name>/run', (Request request, String encodedName) {
    if (scheduleService == null) {
      return errorResponse(404, 'NOT_AVAILABLE', 'Schedule service not configured');
    }

    final name = decodePathSegment(encodedName);

    return switch (scheduleService.runJobNow(name)) {
      RunScheduledJobResult.started => jsonResponse(202, {'name': name, 'status': 'started'}),
      RunScheduledJobResult.alreadyRunning => errorResponse(409, 'CONFLICT', 'Job "$name" is already running'),
      RunScheduledJobResult.notFound => errorResponse(
        404,
        'NOT_FOUND',
        'Job "$name" is not present in the running scheduler or is not runnable on demand. '
            'Newly created or edited jobs require a restart; otherwise check server logs for configuration errors.',
      ),
    };
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

/// Parses request body as JSON or form-encoded data, read through the shared
/// capped reader.
///
/// An empty body means an empty map here, not a rejection: the routes validate
/// their own `"enabled"` / `"status"` fields and publish those messages.
/// Form-encoded `"true"`/`"false"` strings are coerced to [bool].
Future<({Map<String, dynamic>? value, Response? error})> _parseBody(Request request) async {
  final ct = request.headers['content-type'] ?? '';
  final bodyResult = await readRequestBody(request, maxBytes: defaultMaxJsonBodyBytes);
  if (bodyResult.error != null) return (value: null, error: bodyResult.error);
  final body = bodyResult.body!;

  if (ct.startsWith('application/json')) {
    if (body.isEmpty) return (value: <String, dynamic>{}, error: null);
    return decodeJsonObject(body, invalidMessage: 'Invalid request body');
  }

  // Default: form-encoded (HTMX sends application/x-www-form-urlencoded)
  return (value: Uri.splitQueryString(body).map((k, v) => MapEntry(k, _coerceBool(v))), error: null);
}

dynamic _coerceBool(String v) {
  if (v == 'true') return true;
  if (v == 'false') return false;
  return v;
}
