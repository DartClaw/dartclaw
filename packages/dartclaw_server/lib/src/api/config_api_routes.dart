import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/config_serializer.dart';
import '../restart_service.dart';
import '../runtime_config.dart';
import '../scheduling/cron_parser.dart';
import '../scheduling/schedule_service.dart';
import 'allowlist_validator.dart';
import 'api_helpers.dart';
import 'sse_broadcast.dart';

final _log = Logger('ConfigApiRoutes');

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
  ScheduleService? scheduleService,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
  GoogleChatChannel? googleChatChannel,
  EventBus? eventBus,
  ConfigNotifier? configNotifier,
}) {
  ensureDartclawGoogleChatRegistered();
  ensureDartclawWhatsappRegistered();
  ensureGitHubWebhookConfigRegistered();

  final router = Router();
  const serializer = ConfigSerializer();

  // GET /api/config — full config JSON with _meta
  router.get('/api/config', (Request request) async {
    try {
      // Read fresh from disk to reflect PATCH writes (restart-required fields)
      final freshConfig = DartclawConfig.load(configPath: writer.configPath);
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
      final jobs = await writer.readSchedulingJobs();
      return jsonResponse(200, jobs);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read scheduled jobs: $e');
    }
  });

  // GET /api/scheduling/jobs/<name> — fetch a single job by name
  router.get('/api/scheduling/jobs/<name>', (Request request, String name) async {
    try {
      final jobs = await writer.readSchedulingJobs();
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

  // PATCH /api/config — validate, write, apply
  router.patch('/api/config', (Request request) async {
    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }
    final normalizedBody = _normalizeConfigPatch(body);
    if (normalizedBody.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    // Reject scheduling.jobs — use job CRUD endpoints
    if (normalizedBody.containsKey('scheduling.jobs')) {
      return errorResponse(400, 'INVALID_INPUT', 'Use job CRUD endpoints for scheduling.jobs changes');
    }

    late final DartclawConfig freshConfig;
    try {
      freshConfig = DartclawConfig.load(configPath: writer.configPath);
    } catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read config: $e');
    }

    // Validate
    final errors = validator.validate(normalizedBody, currentValues: _currentConfigValues(freshConfig));
    if (errors.isNotEmpty) {
      return jsonResponse(400, {
        'applied': <String>[],
        'pendingRestart': <String>[],
        'errors': errors.map((e) => {'field': e.field, 'message': e.message}).toList(),
      });
    }

    // Partition into live + reloadable + restart
    final liveFields = <String, dynamic>{};
    final reloadableFields = <String, dynamic>{};
    final restartFields = <String, dynamic>{};

    for (final entry in normalizedBody.entries) {
      final meta = ConfigMeta.fields[entry.key];
      if (meta == null) continue; // validated above — should not happen
      switch (meta.mutability) {
        case ConfigMutability.live:
          liveFields[entry.key] = entry.value;
        case ConfigMutability.reloadable:
          reloadableFields[entry.key] = entry.value;
        case ConfigMutability.restart:
        case ConfigMutability.readonly:
          restartFields[entry.key] = entry.value;
      }
    }

    // Write ALL validated fields to YAML (live, reloadable, and restart-required).
    // All fields must be persisted so they survive a restart.
    final allFields = {...liveFields, ...reloadableFields, ...restartFields};
    if (allFields.isNotEmpty) {
      try {
        await writer.updateFields(allFields);
      } on StateError catch (e) {
        return errorResponse(500, 'BACKUP_FAILED', e.message);
      } on FileSystemException catch (e) {
        return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
      }
    }

    // Fire ConfigChangedEvent only for live fields — Tier 1 subscribers handle
    // immediate side-effects. Reloadable fields are handled by ConfigNotifier.reload().
    if (liveFields.isNotEmpty) {
      eventBus?.fire(
        ConfigChangedEvent(
          changedKeys: liveFields.keys.toList(),
          oldValues: <String, dynamic>{},
          newValues: liveFields,
          requiresRestart: false,
          timestamp: DateTime.now(),
        ),
      );
    }

    // Apply reloadable fields via ConfigNotifier.reload() — reads fresh config
    // from disk after YAML write and notifies Reconfigurable services.
    // On failure, fall back to treating reloadable fields as pendingRestart.
    final reloadFallbackFields = <String, dynamic>{};
    if (reloadableFields.isNotEmpty) {
      final notifier = configNotifier;
      if (notifier == null) {
        // Not wired — treat as restart-required.
        reloadFallbackFields.addAll(reloadableFields);
      } else {
        try {
          final newConfig = DartclawConfig.load(configPath: writer.configPath);
          notifier.reload(newConfig);
        } catch (e, st) {
          _log.severe('ConfigNotifier.reload() failed — falling back to pendingRestart for reloadable fields', e, st);
          reloadFallbackFields.addAll(reloadableFields);
        }
      }
    }

    // Create/update restart.pending for restart fields and any reloadable fallbacks.
    final pendingRestartFields = {...restartFields, ...reloadFallbackFields};
    if (pendingRestartFields.isNotEmpty) {
      writeRestartPending(dataDir, pendingRestartFields.keys.toList());
    }

    // Applied = live fields + successfully reloaded reloadable fields
    final appliedFields = {...liveFields, ...reloadableFields}
      ..removeWhere((k, _) => reloadFallbackFields.containsKey(k));

    return jsonResponse(200, {
      'applied': appliedFields.keys.toList(),
      'pendingRestart': pendingRestartFields.keys.toList(),
      'errors': <Map<String, String>>[],
    });
  });

  // POST /api/scheduling/jobs — create a new job
  router.post('/api/scheduling/jobs', (Request request) async {
    final body = await _parseJsonBody(request);
    if (body == null || body.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    // Validate required fields
    final name = body['name'];
    final schedule = body['schedule'];

    if (name is! String || name.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"name" is required and must be a non-empty string');
    }
    if (schedule is! String || schedule.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"schedule" is required and must be a non-empty string');
    }

    // Validate type and type-specific fields
    final typeStr = body['type'] as String? ?? 'prompt';
    if (typeStr != 'prompt' && typeStr != 'task') {
      return errorResponse(400, 'INVALID_INPUT', '"type" must be "prompt" or "task"');
    }

    if (typeStr == 'prompt') {
      final delivery = body['delivery'];
      if (delivery is! String || !const {'announce', 'webhook', 'none'}.contains(delivery)) {
        return errorResponse(400, 'INVALID_INPUT', '"delivery" must be one of: announce, webhook, none');
      }
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"prompt" is required for type: prompt');
      }
    } else {
      // type: task
      final task = body['task'];
      if (task is! Map) {
        return errorResponse(400, 'INVALID_INPUT', '"task" object is required for type: task');
      }
      final taskTitle = task['title'];
      final taskDesc = task['description'];
      final taskType = task['task_type'] ?? task['type'];
      if (taskTitle is! String || taskTitle.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"task.title" is required');
      }
      if (taskDesc is! String || taskDesc.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"task.description" is required');
      }
      if (taskType is! String || taskType.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"task.task_type" is required');
      }
    }

    // Validate cron expression
    try {
      CronExpression.parse(schedule);
    } catch (e) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid cron expression: "$schedule"');
    }

    // Check uniqueness — read fresh from YAML (not startup snapshot).
    final currentJobs = await writer.readSchedulingJobs();
    if (currentJobs.any((j) => j['name'] == name || j['id'] == name)) {
      return errorResponse(409, 'CONFLICT', 'Job "$name" already exists');
    }

    final newJob = <String, dynamic>{
      'name': name,
      'schedule': schedule,
      'type': typeStr,
      if (typeStr == 'prompt') 'delivery': body['delivery'],
      if (typeStr == 'prompt') 'prompt': body['prompt'],
      if (typeStr == 'task') 'task': body['task'],
      if (body['model'] != null) 'model': body['model'],
      if (body['effort'] != null) 'effort': body['effort'],
    };

    // Build updated array and write
    final updatedJobs = [...currentJobs.map((j) => Map<String, dynamic>.from(j)), newJob];

    try {
      await writer.updateFields({'scheduling.jobs': updatedJobs});
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['scheduling.jobs']);

    return jsonResponse(201, {'job': newJob, 'pendingRestart': true});
  });

  // PUT /api/scheduling/jobs/<name> — update existing job
  router.put('/api/scheduling/jobs/<name>', (Request request, String name) async {
    final body = await _parseJsonBody(request);
    if (body == null || body.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    // Read fresh from YAML (not startup snapshot) to avoid overwrite races.
    final currentJobs = await writer.readSchedulingJobs();
    final idx = currentJobs.indexWhere((j) => j['name'] == name || j['id'] == name);
    if (idx == -1) {
      return errorResponse(404, 'NOT_FOUND', 'Job "$name" not found');
    }

    // Determine effective type: use body['type'] if provided, else fall back to existing job's type.
    final existingJob = currentJobs[idx];
    final effectiveType = body['type'] as String? ?? existingJob['type'] as String? ?? 'prompt';

    // Validate changed fields
    if (body.containsKey('schedule')) {
      final schedule = body['schedule'];
      if (schedule is! String || schedule.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"schedule" must be a non-empty string');
      }
      try {
        CronExpression.parse(schedule);
      } catch (e) {
        return errorResponse(400, 'INVALID_INPUT', 'Invalid cron expression: "$schedule"');
      }
    }
    if (body.containsKey('type')) {
      if (effectiveType != 'prompt' && effectiveType != 'task') {
        return errorResponse(400, 'INVALID_INPUT', '"type" must be "prompt" or "task"');
      }
    }
    if (body.containsKey('prompt')) {
      if (effectiveType != 'prompt') {
        return errorResponse(400, 'INVALID_INPUT', '"prompt" is only valid for type: prompt');
      }
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"prompt" must be a non-empty string');
      }
    }
    if (body.containsKey('task')) {
      if (effectiveType != 'task') {
        return errorResponse(400, 'INVALID_INPUT', '"task" is only valid for type: task');
      }
    }
    if (body.containsKey('delivery')) {
      final delivery = body['delivery'];
      if (delivery is! String || !const {'announce', 'webhook', 'none'}.contains(delivery)) {
        return errorResponse(400, 'INVALID_INPUT', '"delivery" must be one of: announce, webhook, none');
      }
    }

    // Merge updates
    final updatedJobs = currentJobs.map((j) => Map<String, dynamic>.from(j)).toList();
    final job = updatedJobs[idx];
    for (final entry in body.entries) {
      if (entry.key != 'name') job[entry.key] = entry.value;
    }

    try {
      await writer.updateFields({'scheduling.jobs': updatedJobs});
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['scheduling.jobs']);

    return jsonResponse(200, {'job': job, 'pendingRestart': true});
  });

  // DELETE /api/scheduling/jobs/<name>
  router.delete('/api/scheduling/jobs/<name>', (Request request, String name) async {
    // Read fresh from YAML (not startup snapshot) to avoid overwrite races.
    final currentJobs = await writer.readSchedulingJobs();
    final idx = currentJobs.indexWhere((j) => j['name'] == name || j['id'] == name);
    if (idx == -1) {
      return errorResponse(404, 'NOT_FOUND', 'Job "$name" not found');
    }

    final updatedJobs = currentJobs.map((j) => Map<String, dynamic>.from(j)).toList();
    updatedJobs.removeAt(idx);

    try {
      await writer.updateFields({'scheduling.jobs': updatedJobs});
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['scheduling.jobs']);

    return jsonResponse(200, {'deleted': true, 'pendingRestart': true});
  });

  // --- Automation scheduled task CRUD ---

  // POST /api/scheduling/tasks — create a new scheduled task
  router.post('/api/scheduling/tasks', (Request request) async {
    final body = await _parseJsonBody(request);
    if (body == null || body.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    final id = body['id'];
    final schedule = body['schedule'];
    final title = body['title'];
    final description = body['description'];
    final type = body['type'];

    if (id is! String || id.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"id" is required and must be a non-empty string');
    }
    if (schedule is! String || schedule.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"schedule" is required and must be a non-empty string');
    }
    if (title is! String || title.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"title" is required and must be a non-empty string');
    }
    if (description is! String || description.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"description" is required and must be a non-empty string');
    }
    if (type is! String || type.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"type" is required and must be a non-empty string');
    }

    // Validate cron expression
    try {
      CronExpression.parse(schedule);
    } catch (e) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid cron expression: "$schedule"');
    }

    // Check uniqueness — read fresh from YAML (not startup snapshot).
    final currentJobs = await writer.readSchedulingJobs();
    if (currentJobs.where((j) => j['type'] == 'task').any((j) => j['id'] == id || j['name'] == id)) {
      return errorResponse(409, 'CONFLICT', 'Scheduled task "$id" already exists');
    }

    final newJob = <String, dynamic>{
      'id': id,
      'type': 'task',
      'schedule': schedule,
      'enabled': body['enabled'] ?? true,
      'task': <String, dynamic>{
        'title': title,
        'description': description,
        'type': type,
        if (body['acceptanceCriteria'] is String && (body['acceptanceCriteria'] as String).isNotEmpty)
          'acceptance_criteria': body['acceptanceCriteria'],
        if (body['autoStart'] != null) 'auto_start': body['autoStart'],
      },
    };

    final updatedJobs = [...currentJobs.map((j) => Map<String, dynamic>.from(j)), newJob];

    try {
      await writer.updateFields({'scheduling.jobs': updatedJobs});
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['scheduling.jobs']);

    return jsonResponse(201, {'task': newJob, 'pendingRestart': true});
  });

  // PUT /api/scheduling/tasks/<id> — update existing scheduled task
  router.put('/api/scheduling/tasks/<id>', (Request request, String id) async {
    final body = await _parseJsonBody(request);
    if (body == null || body.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    final currentJobs = await writer.readSchedulingJobs();
    final idx = currentJobs.indexWhere((j) => j['type'] == 'task' && (j['id'] == id || j['name'] == id));
    if (idx == -1) {
      return errorResponse(404, 'NOT_FOUND', 'Scheduled task "$id" not found');
    }

    // Validate cron if changed
    if (body.containsKey('schedule')) {
      final schedule = body['schedule'];
      if (schedule is! String || schedule.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"schedule" must be a non-empty string');
      }
      try {
        CronExpression.parse(schedule);
      } catch (e) {
        return errorResponse(400, 'INVALID_INPUT', 'Invalid cron expression: "$schedule"');
      }
    }

    // Merge updates
    final updatedJobs = currentJobs.map((j) => Map<String, dynamic>.from(j)).toList();
    final job = updatedJobs[idx];
    if (body.containsKey('schedule')) job['schedule'] = body['schedule'];
    if (body.containsKey('enabled')) job['enabled'] = body['enabled'];

    // Update nested task fields
    final taskMap = job['task'] is Map ? Map<String, dynamic>.from(job['task'] as Map) : <String, dynamic>{};
    if (body.containsKey('title')) taskMap['title'] = body['title'];
    if (body.containsKey('description')) taskMap['description'] = body['description'];
    if (body.containsKey('type')) taskMap['type'] = body['type'];
    if (body.containsKey('acceptanceCriteria')) {
      taskMap['acceptance_criteria'] = body['acceptanceCriteria'];
    }
    if (body.containsKey('autoStart')) taskMap['auto_start'] = body['autoStart'];
    job['task'] = taskMap;

    try {
      await writer.updateFields({'scheduling.jobs': updatedJobs});
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['scheduling.jobs']);

    return jsonResponse(200, {'task': job, 'pendingRestart': true});
  });

  // DELETE /api/scheduling/tasks/<id>
  router.delete('/api/scheduling/tasks/<id>', (Request request, String id) async {
    final currentJobs = await writer.readSchedulingJobs();
    final idx = currentJobs.indexWhere((j) => j['type'] == 'task' && (j['id'] == id || j['name'] == id));
    if (idx == -1) {
      return errorResponse(404, 'NOT_FOUND', 'Scheduled task "$id" not found');
    }

    final updatedJobs = currentJobs.map((j) => Map<String, dynamic>.from(j)).toList();
    updatedJobs.removeAt(idx);

    try {
      await writer.updateFields({'scheduling.jobs': updatedJobs});
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['scheduling.jobs']);

    return jsonResponse(200, {'deleted': true, 'pendingRestart': true});
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
    return Response.ok(
      controller.stream,
      headers: {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive'},
    );
  });

  // --- Allowlist CRUD endpoints ---

  DmAccessController? resolveController(String type) {
    if (type == 'whatsapp') return whatsAppChannel?.dmAccess;
    if (type == 'signal') return signalChannel?.dmAccess;
    if (type == 'google_chat') return googleChatChannel?.dmAccess;
    return null;
  }

  // GET /api/config/channels/<type>/dm-allowlist
  router.get('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    final controller = resolveController(type);
    if (controller != null) {
      return jsonResponse(200, {'allowlist': controller.allowlist.toList()});
    }
    if (type == 'google_chat') {
      final entries = await writer.readChannelAllowlist(type, 'dm_allowlist');
      return jsonResponse(200, {'allowlist': entries});
    }
    if (controller == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    return jsonResponse(200, {'allowlist': controller.allowlist.toList()});
  });

  // POST /api/config/channels/<type>/dm-allowlist
  router.post('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    final controller = resolveController(type);
    if (controller == null && type != 'google_chat') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final entry = body['entry'];
    if (entry is! String || entry.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"entry" is required and must be a non-empty string');
    }

    final validationError = validateAllowlistEntry(type, entry);
    if (validationError != null) {
      return errorResponse(400, 'INVALID_INPUT', validationError);
    }

    final currentAllowlist = controller?.allowlist.toList() ?? await writer.readChannelAllowlist(type, 'dm_allowlist');
    if (currentAllowlist.contains(entry)) {
      return errorResponse(409, 'CONFLICT', 'Entry "$entry" already in allowlist');
    }

    // Persist BEFORE mutating controller — if write fails, state stays consistent
    final updatedList = [...currentAllowlist, entry];
    try {
      await writer.writeChannelAllowlist(type, 'dm_allowlist', updatedList);
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    // Write succeeded — now mutate live controller
    controller?.addToAllowlist(entry);
    return jsonResponse(200, {'added': true, 'allowlist': updatedList});
  });

  // DELETE /api/config/channels/<type>/dm-allowlist
  router.delete('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    final controller = resolveController(type);
    if (controller == null && type != 'google_chat') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final entry = body['entry'];
    if (entry is! String || entry.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"entry" is required and must be a non-empty string');
    }

    final currentAllowlist = controller?.allowlist.toList() ?? await writer.readChannelAllowlist(type, 'dm_allowlist');
    if (!currentAllowlist.contains(entry)) {
      return errorResponse(404, 'NOT_FOUND', 'Entry "$entry" not in allowlist');
    }

    // Persist BEFORE mutating controller — if write fails, state stays consistent
    final updatedList = currentAllowlist.where((e) => e != entry).toList();
    try {
      await writer.writeChannelAllowlist(type, 'dm_allowlist', updatedList);
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    // Write succeeded — now mutate live controller
    controller?.removeFromAllowlist(entry);
    return jsonResponse(200, {'removed': true, 'allowlist': updatedList});
  });

  // --- Group Allowlist CRUD endpoints (restart-required) ---

  // GET /api/config/channels/<type>/group-allowlist
  router.get('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    if (type != 'whatsapp' && type != 'signal' && type != 'google_chat') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    final channel = switch (type) {
      'whatsapp' => whatsAppChannel,
      'signal' => signalChannel,
      _ => googleChatChannel,
    };
    if (type != 'google_chat' && channel == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    // Read from YAML to reflect pending (not-yet-restarted) changes.
    final entries = await writer.readChannelAllowlist(type, 'group_allowlist');
    return jsonResponse(200, {'allowlist': entries});
  });

  // POST /api/config/channels/<type>/group-allowlist
  router.post('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    if (type != 'whatsapp' && type != 'signal' && type != 'google_chat') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    final channel = switch (type) {
      'whatsapp' => whatsAppChannel,
      'signal' => signalChannel,
      _ => googleChatChannel,
    };
    if (type != 'google_chat' && channel == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final entry = body['entry'];
    if (entry is! String || entry.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"entry" is required and must be a non-empty string');
    }

    final current = await writer.readChannelAllowlist(type, 'group_allowlist');
    if (current.contains(entry)) {
      return errorResponse(409, 'CONFLICT', 'Entry "$entry" already in group allowlist');
    }

    final updated = [...current, entry];
    try {
      await writer.writeChannelAllowlist(type, 'group_allowlist', updated);
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['channels.$type.group_allowlist']);

    eventBus?.fire(
      ConfigChangedEvent(
        changedKeys: ['channels.$type.group_allowlist'],
        oldValues: {'channels.$type.group_allowlist': current},
        newValues: {'channels.$type.group_allowlist': updated},
        requiresRestart: true,
        timestamp: DateTime.now(),
      ),
    );

    return jsonResponse(201, {'added': true, 'allowlist': updated});
  });

  // DELETE /api/config/channels/<type>/group-allowlist
  router.delete('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    if (type != 'whatsapp' && type != 'signal' && type != 'google_chat') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    final channel = switch (type) {
      'whatsapp' => whatsAppChannel,
      'signal' => signalChannel,
      _ => googleChatChannel,
    };
    if (type != 'google_chat' && channel == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final entry = body['entry'];
    if (entry is! String || entry.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"entry" is required and must be a non-empty string');
    }

    final current = await writer.readChannelAllowlist(type, 'group_allowlist');
    if (!current.contains(entry)) {
      return errorResponse(404, 'NOT_FOUND', 'Entry "$entry" not in group allowlist');
    }

    final updated = current.where((e) => e != entry).toList();
    try {
      await writer.writeChannelAllowlist(type, 'group_allowlist', updated);
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['channels.$type.group_allowlist']);

    return jsonResponse(200, {'removed': true, 'allowlist': updated});
  });

  // --- DM Pairing endpoints ---

  // GET /api/channels/<type>/dm-pairing — list pending pairings
  router.get('/api/channels/<type>/dm-pairing', (Request request, String type) {
    final controller = resolveController(type);
    if (controller == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }

    final pending = controller.pendingPairings;
    final now = DateTime.now();
    return jsonResponse(200, {
      'pending': pending.map((p) {
        final remaining = p.expiresAt.difference(now).inSeconds;
        return {
          'code': p.code,
          'senderId': p.jid,
          'displayName': p.displayName,
          'expiresAt': p.expiresAt.toUtc().toIso8601String(),
          'remainingSeconds': remaining > 0 ? remaining : 0,
        };
      }).toList(),
      'total': pending.length,
    });
  });

  // POST /api/channels/<type>/dm-pairing/confirm — approve a pairing
  router.post('/api/channels/<type>/dm-pairing/confirm', (Request request, String type) async {
    final controller = resolveController(type);
    if (controller == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final code = body['code'];
    if (code is! String || code.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"code" is required');
    }

    // Look up the pairing before confirming (confirmPairing removes it)
    final pairing = controller.pendingPairings.where((p) => p.code == code).firstOrNull;
    if (pairing == null) {
      return errorResponse(404, 'NOT_FOUND', 'Pairing code not found or expired');
    }

    // Compute what allowlist will look like after confirmation
    final updatedList = [...controller.allowlist, pairing.jid];

    // Persist BEFORE mutating controller — if write fails, state stays consistent
    try {
      await writer.writeChannelAllowlist(type, 'dm_allowlist', updatedList);
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    // Write succeeded — now confirm (mutates controller: removes pending + adds to allowlist)
    final confirmed = controller.confirmPairing(code);
    if (!confirmed) {
      return errorResponse(404, 'NOT_FOUND', 'Pairing code not found or expired');
    }

    return jsonResponse(200, {'confirmed': true, 'senderId': pairing.jid});
  });

  // POST /api/channels/<type>/dm-pairing/reject — reject a pairing
  router.post('/api/channels/<type>/dm-pairing/reject', (Request request, String type) async {
    final controller = resolveController(type);
    if (controller == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }

    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }

    final code = body['code'];
    if (code is! String || code.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"code" is required');
    }

    final rejected = controller.rejectPairing(code);
    if (!rejected) {
      return errorResponse(404, 'NOT_FOUND', 'Pairing code not found');
    }

    return jsonResponse(200, {'rejected': true});
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

Map<String, dynamic> _currentConfigValues(DartclawConfig config) {
  final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);
  final audience = googleChatConfig.audience;
  GitHubWebhookConfig? githubConfig;
  try {
    githubConfig = config.extension<GitHubWebhookConfig>('github');
  } catch (_) {
    githubConfig = null;
  }
  return {
    'channels.google_chat.enabled': googleChatConfig.enabled,
    'channels.google_chat.service_account': googleChatConfig.serviceAccount,
    'channels.google_chat.audience.type': switch (audience?.mode) {
      GoogleChatAudienceMode.appUrl => 'app-url',
      GoogleChatAudienceMode.projectNumber => 'project-number',
      null => null,
    },
    'channels.google_chat.audience.value': audience?.value,
    'channels.google_chat.dm_access': googleChatConfig.dmAccess.name,
    'channels.google_chat.group_access': googleChatConfig.groupAccess.name,
    'channels.google_chat.require_mention': googleChatConfig.requireMention,
    'github.enabled': githubConfig?.enabled,
    'github.webhook_secret': githubConfig?.webhookSecret,
    'github.webhook_path': githubConfig?.webhookPath,
  };
}

// --- restart.pending helpers ---

/// Writes or merges restart-pending fields.
///
/// Uses atomic write (temp + rename) for crash safety.
void writeRestartPending(String dataDir, List<String> fields) {
  final filePath = p.join(dataDir, 'restart.pending');
  final file = File(filePath);

  List<String> existingFields = [];
  if (file.existsSync()) {
    try {
      final content = file.readAsStringSync();
      final parsed = jsonDecode(content) as Map<String, dynamic>;
      final raw = parsed['fields'];
      if (raw is List) {
        existingFields = raw.whereType<String>().toList();
      }
    } catch (e) {
      _log.fine('Corrupted restart fields file — overwriting: $e');
    }
  }

  // Merge and deduplicate
  final merged = {...existingFields, ...fields}.toList();

  final json = jsonEncode({'timestamp': DateTime.now().toUtc().toIso8601String(), 'fields': merged});

  // Atomic write
  final tempFile = File('$filePath.tmp');
  tempFile.writeAsStringSync(json);
  tempFile.renameSync(filePath);
}

/// Reads restart.pending, returning null if file doesn't exist.
Map<String, dynamic>? readRestartPending(String dataDir) {
  final file = File(p.join(dataDir, 'restart.pending'));
  if (!file.existsSync()) return null;
  try {
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    _log.fine('Failed to read restart.pending: $e');
    return null;
  }
}

// --- HTTP helpers ---

Future<Map<String, dynamic>?> _parseJsonBody(Request request) async {
  final body = await request.readAsString();
  if (body.isEmpty) return null;
  try {
    final parsed = jsonDecode(body);
    if (parsed is Map<String, dynamic>) return parsed;
    return null;
  } catch (e) {
    _log.fine('Failed to parse JSON request body: $e');
    return null;
  }
}

Map<String, dynamic> _normalizeConfigPatch(Map<String, dynamic> body) {
  final normalized = <String, dynamic>{};
  for (final entry in body.entries) {
    normalized.addAll(_normalizeConfigPatchEntry(entry.key, entry.value, body));
  }
  return normalized;
}

Map<String, dynamic> _normalizeConfigPatchEntry(String path, Object? value, Map<String, dynamic> rawBody) {
  final normalizedValue = _normalizeConfigPatchValue(path, value);
  final normalized = <String, dynamic>{path: normalizedValue};
  final providerPath = _providerSiblingPath(path);
  if (providerPath == null || rawBody.containsKey(providerPath) || normalizedValue is! String) {
    return normalized;
  }

  final shorthand = ProviderIdentity.parseProviderModelShorthand(normalizedValue);
  if (shorthand == null) {
    return normalized;
  }

  normalized[path] = shorthand.model;
  normalized[providerPath] = shorthand.provider;
  return normalized;
}

Object? _normalizeConfigPatchValue(String path, Object? value) {
  final meta = ConfigMeta.fields[path];
  if (meta != null && meta.nullable && value is String && value.trim().isEmpty) {
    return null;
  }
  if (path.endsWith('.task_trigger.default_type') && value is String) {
    return TaskTriggerConfig.normalizeDefaultType(value);
  }
  return value;
}

String? _providerSiblingPath(String path) => switch (path) {
  'agent.model' => 'agent.provider',
  'workflow.defaults.workflow.model' => 'workflow.defaults.workflow.provider',
  'workflow.defaults.planner.model' => 'workflow.defaults.planner.provider',
  'workflow.defaults.executor.model' => 'workflow.defaults.executor.provider',
  'workflow.defaults.reviewer.model' => 'workflow.defaults.reviewer.provider',
  _ => null,
};
