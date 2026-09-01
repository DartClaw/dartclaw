import 'dart:async';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/request_auth_context.dart';
import '../config/config_load.dart';
import '../config/config_serializer.dart';
import '../restart_service.dart';
import '../runtime_config.dart';
import '../scheduling/schedule_mutation.dart';
import 'api_helpers.dart';
import 'channel_access_service.dart';
import 'config_apply_service.dart';
import 'guard_editor_service.dart';
import 'sse_broadcast.dart';

export '../restart_service.dart' show readRestartPending, restartPendingFields, writeRestartPending;

const _maxConfigJsonBodyBytes = 128 * 1024;

/// Config read/write API endpoints.
///
/// Separate from [configRoutes] which handles ephemeral Tier 1 toggles.
/// This router handles persistent config editing (YAML writes) and
/// structured config reading with metadata.
Router configApiRoutes({
  required DartclawConfig config,
  required ConfigWriter writer,
  required ConfigValidator validator,
  required RuntimeConfig runtimeConfig,
  required String dataDir,
  RestartService? restartService,
  SseBroadcast? sseBroadcast,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
  GoogleChatChannel? googleChatChannel,
  EventBus? eventBus,
  ConfigNotifier? configNotifier,
  GuardChain? guardChain,
  ChannelAccessService? channelAccessService,
  GuardEditorService? guardEditorService,
}) {
  ensureGitHubWebhookConfigRegistered();

  final router = Router();
  const serializer = ConfigSerializer();
  final scheduleMutations = ScheduleMutationService(writer: writer, dataDir: dataDir);
  final channelAccess =
      channelAccessService ??
      ChannelAccessService(
        writer: writer,
        dataDir: dataDir,
        whatsAppChannel: whatsAppChannel,
        signalChannel: signalChannel,
        googleChatChannel: googleChatChannel,
        eventBus: eventBus,
      );

  // GET /api/config — full config JSON with _meta
  router.get('/api/config', (Request request) async {
    try {
      // Read fresh from disk to reflect PATCH writes (restart-required fields)
      final freshConfig = loadDartclawConfig(configPath: writer.configPath);
      final json = serializer.toJson(freshConfig, runtime: runtimeConfig);

      // Build _meta
      final pending = readRestartPending(dataDir);
      json['_meta'] = {
        'configPath': writer.configPath,
        'lastBackup': writer.lastBackupTime?.toUtc().toIso8601String(),
        'restartPending': pending != null,
        'pendingFields': pending?['fields'] ?? <String>[],
        'fields': serializer.metaJson(),
      };

      return jsonResponse(200, json);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read config: $e');
    }
  });

  // GET /api/scheduling/jobs — list jobs from the current YAML config
  router.get('/api/scheduling/jobs', (Request request) async {
    try {
      final jobs = await scheduleMutations.readJobs();
      return jsonResponse(200, jobs);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read scheduled jobs: $e');
    }
  });

  // GET /api/scheduling/jobs/<name> — fetch a single job by name
  router.get('/api/scheduling/jobs/<name>', (Request request, String rawName) async {
    final name = decodePathSegment(rawName);
    try {
      final jobs = await scheduleMutations.readJobs();
      final job = jobs.firstWhere(
        (entry) => entry['name'] == name || entry['id'] == name,
        orElse: () => const <String, dynamic>{},
      );
      if (job.isEmpty) {
        return errorResponse(404, 'JOB_NOT_FOUND', 'Scheduled job not found: $name');
      }
      return jsonResponse(200, job);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read scheduled job: $e');
    }
  });

  final guardEditor =
      guardEditorService ??
      GuardEditorService(writer: writer, dataDir: dataDir, configNotifier: configNotifier, guardChain: guardChain);

  // GET /api/config/guards — editable extension state.
  router.get('/api/config/guards', (Request request) {
    return jsonResponse(200, guardEditor.readState());
  });

  // POST /api/config/guards/<guard>/<field> — append an editable extension.
  router.post('/api/config/guards/<guard>/<field>', (Request request, String guard, String field) async {
    final denied = _requireGuardEditorAdmin(request, 'Guard editing requires an admin user');
    if (denied != null) return denied;
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    final body = parsedBody.value!;
    late final GuardEditorResult result;
    return _writeConfigOrError(
      () async {
        result = await guardEditor.createEntry(guard, field, body.containsKey('value') ? body['value'] : body);
      },
      () => jsonResponse(201, result.toJson()),
      onValidation: _guardEditorValidationResponse,
    );
  });

  // PUT /api/config/guards/<guard>/<field>/<index> — replace an editable extension.
  router.put('/api/config/guards/<guard>/<field>/<index>', (
    Request request,
    String guard,
    String field,
    String index,
  ) async {
    final denied = _requireGuardEditorAdmin(request, 'Guard editing requires an admin user');
    if (denied != null) return denied;
    const invalidBody = 'Request body must be valid JSON and index must be numeric';
    final parsedBody = await readJsonObject(request, maxBytes: _maxConfigJsonBodyBytes, invalidMessage: invalidBody);
    if (parsedBody.error != null) return parsedBody.error;
    final body = parsedBody.value!;
    final parsedIndex = int.tryParse(index);
    if (parsedIndex == null) {
      return errorResponse(400, 'INVALID_INPUT', invalidBody);
    }
    late final GuardEditorResult result;
    return _writeConfigOrError(
      () async {
        result = await guardEditor.updateEntry(
          guard,
          field,
          parsedIndex,
          body.containsKey('value') ? body['value'] : body,
        );
      },
      () => jsonResponse(200, result.toJson()),
      onValidation: _guardEditorValidationResponse,
    );
  });

  // DELETE /api/config/guards/<guard>/<field>/<index> — remove an editable extension.
  router.delete('/api/config/guards/<guard>/<field>/<index>', (
    Request request,
    String guard,
    String field,
    String index,
  ) async {
    final denied = _requireGuardEditorAdmin(request, 'Guard editing requires an admin user');
    if (denied != null) return denied;
    final parsedIndex = int.tryParse(index);
    if (parsedIndex == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Index must be numeric');
    }
    late final GuardEditorResult result;
    return _writeConfigOrError(
      () async {
        result = await guardEditor.deleteEntry(guard, field, parsedIndex);
      },
      () => jsonResponse(200, result.toJson()),
      onValidation: _guardEditorValidationResponse,
    );
  });

  // POST /api/config/guards/test — evaluate a sample through real guard semantics.
  router.post('/api/config/guards/test', (Request request) async {
    final denied = _requireGuardEditorAdmin(request, 'Guard testing requires an admin user');
    if (denied != null) return denied;
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    final body = parsedBody.value!;
    final guard = body['guard'];
    if (guard is! String || !guardEditorFamilies.contains(guard)) {
      return errorResponse(400, 'INVALID_INPUT', '"guard" must be one of ${guardEditorFamilies.join(', ')}');
    }
    try {
      final result = await guardEditor.testInput(guard, body);
      return jsonResponse(200, result);
    } on GuardEditorValidationException catch (e) {
      return _guardEditorValidationResponse(e);
    }
  });

  final configApply = ConfigApplyService(
    writer: writer,
    validator: validator,
    dataDir: dataDir,
    containerIsolationActive: config.container.enabled,
    eventBus: eventBus,
    configNotifier: configNotifier,
  );

  // PATCH /api/config — validate, write, apply
  router.patch('/api/config', (Request request) async {
    if (!requestHasAdminAccess(request)) {
      return errorResponse(403, 'FORBIDDEN', 'Config changes require an admin user');
    }
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    final normalizedBody = normalizeConfigPatch(parsedBody.value!);
    if (normalizedBody.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    // Reject scheduling.jobs — use job CRUD endpoints
    if (normalizedBody.containsKey('scheduling.jobs')) {
      return errorResponse(400, 'INVALID_INPUT', 'Use job CRUD endpoints for scheduling.jobs changes');
    }

    final ConfigApplyResult result;
    try {
      result = await configApply.apply(normalizedBody);
    } on ConfigReadException catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read config: ${e.cause}');
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    return jsonResponse(result.isValid ? 200 : 400, {
      'applied': result.applied,
      'pendingRestart': result.pendingRestart,
      'errors': result.errors.map((e) => {'field': e.field, 'message': e.message}).toList(),
    });
  });

  // POST /api/scheduling/jobs — create a new job
  router.post('/api/scheduling/jobs', (Request request) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be a non-empty JSON object',
      requireNonEmpty: true,
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _scheduleMutationResponse(
      await scheduleMutations.createJob(parsedBody.value!),
      applied: (job) => jsonResponse(201, {'job': job, 'pendingRestart': true}),
    );
  });

  // PUT /api/scheduling/jobs/<name> — update existing job
  router.put('/api/scheduling/jobs/<name>', (Request request, String rawName) async {
    final name = decodePathSegment(rawName);
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be a non-empty JSON object',
      requireNonEmpty: true,
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _scheduleMutationResponse(
      await scheduleMutations.updateJob(name, parsedBody.value!),
      applied: (job) => jsonResponse(200, {'job': job, 'pendingRestart': true}),
    );
  });

  // DELETE /api/scheduling/jobs/<name>
  router.delete('/api/scheduling/jobs/<name>', (Request request, String rawName) async {
    final name = decodePathSegment(rawName);
    return _scheduleMutationResponse(
      await scheduleMutations.deleteJob(name),
      applied: (_) => jsonResponse(200, {'deleted': true, 'pendingRestart': true}),
    );
  });

  // --- Automation scheduled task CRUD ---

  // POST /api/scheduling/tasks — create a new scheduled task
  router.post('/api/scheduling/tasks', (Request request) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be a non-empty JSON object',
      requireNonEmpty: true,
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _scheduleMutationResponse(
      await scheduleMutations.createTask(parsedBody.value!),
      applied: (task) => jsonResponse(201, {'task': task, 'pendingRestart': true}),
    );
  });

  // PUT /api/scheduling/tasks/<id> — update existing scheduled task
  router.put('/api/scheduling/tasks/<id>', (Request request, String rawId) async {
    final id = decodePathSegment(rawId);
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be a non-empty JSON object',
      requireNonEmpty: true,
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _scheduleMutationResponse(
      await scheduleMutations.updateTask(id, parsedBody.value!),
      applied: (task) => jsonResponse(200, {'task': task, 'pendingRestart': true}),
    );
  });

  // DELETE /api/scheduling/tasks/<id>
  router.delete('/api/scheduling/tasks/<id>', (Request request, String rawId) async {
    final id = decodePathSegment(rawId);
    return _scheduleMutationResponse(
      await scheduleMutations.deleteTask(id),
      applied: (_) => jsonResponse(200, {'deleted': true, 'pendingRestart': true}),
    );
  });

  // POST /api/system/restart — graceful restart
  router.post('/api/system/restart', (Request request) async {
    final rs = restartService;
    if (rs == null) {
      return errorResponse(503, 'RESTART_UNAVAILABLE', 'Restart service not configured');
    }
    if (rs.isRestarting) {
      return errorResponse(409, 'RESTART_IN_PROGRESS', 'Restart already in progress');
    }

    // Read current pending fields from restart.pending (if any).
    final pending = readRestartPending(dataDir);
    final fields = (pending?['fields'] as List<dynamic>?)?.whereType<String>().toList() ?? <String>[];

    // Fire-and-forget: restart happens async (response sent before exit).
    unawaited(rs.restart(pendingFields: fields));

    return jsonResponse(200, {
      'status': 'restarting',
      'message': 'Server is restarting. Active turns will drain first.',
      'drainDeadlineSeconds': rs.drainDeadline.inSeconds,
    });
  });

  // GET /api/events — global SSE broadcast stream (restart notifications, etc.)
  router.get('/api/events', (Request request) {
    final sse = sseBroadcast;
    if (sse == null) {
      return errorResponse(503, 'SSE_UNAVAILABLE', 'SSE broadcast not configured');
    }
    final controller = sse.subscribe();
    return sseResponse(controller.stream);
  });

  // --- Allowlist CRUD endpoints ---

  // GET /api/config/channels/<type>/dm-allowlist
  router.get('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    return _channelAccessResponse(await channelAccess.readAllowlist(type, 'dm'));
  });

  // POST /api/config/channels/<type>/dm-allowlist
  router.post('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _channelAccessResponse(await channelAccess.addAllowlist(type, 'dm', parsedBody.value!['entry']));
  });

  // DELETE /api/config/channels/<type>/dm-allowlist
  router.delete('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _channelAccessResponse(await channelAccess.removeAllowlist(type, 'dm', parsedBody.value!['entry']));
  });

  // --- Group Allowlist CRUD endpoints (restart-required) ---

  // GET /api/config/channels/<type>/group-allowlist
  router.get('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    return _channelAccessResponse(await channelAccess.readAllowlist(type, 'group'));
  });

  // POST /api/config/channels/<type>/group-allowlist
  router.post('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _channelAccessResponse(
      await channelAccess.addAllowlist(type, 'group', parsedBody.value!['entry']),
      successStatus: 201,
    );
  });

  // DELETE /api/config/channels/<type>/group-allowlist
  router.delete('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _channelAccessResponse(await channelAccess.removeAllowlist(type, 'group', parsedBody.value!['entry']));
  });

  // --- DM Pairing endpoints ---

  // GET /api/channels/<type>/dm-pairing — list pending pairings
  router.get('/api/channels/<type>/dm-pairing', (Request request, String type) {
    return _channelAccessResponse(channelAccess.readPairings(type));
  });

  // POST /api/channels/<type>/dm-pairing/confirm — approve a pairing
  router.post('/api/channels/<type>/dm-pairing/confirm', (Request request, String type) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _channelAccessResponse(await channelAccess.confirmPairing(type, parsedBody.value!['code']));
  });

  // POST /api/channels/<type>/dm-pairing/reject — reject a pairing
  router.post('/api/channels/<type>/dm-pairing/reject', (Request request, String type) async {
    final parsedBody = await readJsonObject(
      request,
      maxBytes: _maxConfigJsonBodyBytes,
      invalidMessage: 'Request body must be valid JSON',
    );
    if (parsedBody.error != null) return parsedBody.error;
    return _channelAccessResponse(channelAccess.rejectPairing(type, parsedBody.value!['code']));
  });

  // GET /api/channels/pairing-counts — pending counts for badge display
  router.get('/api/channels/pairing-counts', (Request request) {
    return jsonResponse(200, {
      'whatsapp': whatsAppChannel?.dmAccess.pendingPairings.length ?? 0,
      'signal': signalChannel?.dmAccess.pendingPairings.length ?? 0,
      'google_chat': googleChatChannel?.dmAccess?.pendingPairings.length ?? 0,
    });
  });

  return router;
}

// --- HTTP helpers ---

Response _scheduleMutationResponse(
  ScheduleMutationResult result, {
  required Response Function(Map<String, dynamic>? value) applied,
}) => switch (result) {
  ScheduleMutationApplied(:final value) => applied(value),
  ScheduleMutationRefused(:final refusal) => errorResponse(refusal.status, refusal.code, refusal.message),
};

Response _channelAccessResponse(ChannelAccessResult result, {int successStatus = 200}) => switch (result) {
  ChannelAccessApplied(:final body) => jsonResponse(successStatus, body),
  ChannelAccessRefused(:final status, :final code, :final message) => errorResponse(status, code, message),
};

/// Runs [write], returning [onSuccess] on completion. Maps the shared config-write
/// failure modes to their canonical responses: [StateError] → 500 `BACKUP_FAILED`,
/// [FileSystemException] → 500 `WRITE_FAILED`. When [onValidation] is supplied, a
/// [GuardEditorValidationException] is routed through it instead of propagating.
Future<Response> _writeConfigOrError(
  Future<void> Function() write,
  Response Function() onSuccess, {
  Response Function(GuardEditorValidationException)? onValidation,
}) async {
  try {
    await write();
    return onSuccess();
  } on GuardEditorValidationException catch (e) {
    if (onValidation == null) rethrow;
    return onValidation(e);
  } on StateError catch (e) {
    return errorResponse(500, 'BACKUP_FAILED', e.message);
  } on FileSystemException catch (e) {
    return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
  }
}

/// Returns a 403 response when [request] lacks guard-editor admin access, else null.
Response? _requireGuardEditorAdmin(Request request, String message) {
  if (_guardEditorCanMutate(request)) return null;
  return errorResponse(403, 'FORBIDDEN', message);
}

Response _guardEditorValidationResponse(GuardEditorValidationException exception) {
  return jsonResponse(400, {
    'applied': <String>[],
    'pendingRestart': <String>[],
    'errors': exception.errors.map((message) => {'field': 'guards', 'message': message}).toList(),
  });
}

bool _guardEditorCanMutate(Request request) {
  return requestHasAdminAccess(request);
}
