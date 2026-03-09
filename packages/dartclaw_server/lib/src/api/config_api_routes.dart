import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/config_meta.dart';
import 'allowlist_validator.dart';
import 'api_helpers.dart';
import '../config/config_serializer.dart';
import '../config/config_validator.dart';
import '../config/config_writer.dart';
import '../restart_service.dart';
import '../runtime_config.dart';
import '../scheduling/cron_parser.dart';
import '../scheduling/schedule_service.dart';
import 'sse_broadcast.dart';

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
  HeartbeatScheduler? heartbeat,
  WorkspaceGitSync? gitSync,
  ScheduleService? scheduleService,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
}) {
  final router = Router();
  const serializer = ConfigSerializer();

  // GET /api/config — full config JSON with _meta
  router.get('/api/config', (Request request) async {
    try {
      final json = serializer.toJson(config, runtime: runtimeConfig);

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

  // PATCH /api/config — validate, write, apply
  router.patch('/api/config', (Request request) async {
    final body = await _parseJsonBody(request);
    if (body == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be valid JSON');
    }
    if (body.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    // Reject scheduling.jobs — use job CRUD endpoints
    if (body.containsKey('scheduling.jobs')) {
      return errorResponse(400, 'INVALID_INPUT', 'Use job CRUD endpoints for scheduling.jobs changes');
    }

    // Validate
    final errors = validator.validate(body);
    if (errors.isNotEmpty) {
      return jsonResponse(400, {
        'applied': <String>[],
        'pendingRestart': <String>[],
        'errors': errors.map((e) => {'field': e.field, 'message': e.message}).toList(),
      });
    }

    // Partition into live + restart
    final liveFields = <String, dynamic>{};
    final restartFields = <String, dynamic>{};

    for (final entry in body.entries) {
      final meta = ConfigMeta.fields[entry.key];
      if (meta == null) continue; // validated above — should not happen
      if (meta.mutability == ConfigMutability.live) {
        liveFields[entry.key] = entry.value;
      } else {
        restartFields[entry.key] = entry.value;
      }
    }

    // Write ALL validated fields to YAML (both live and restart-required).
    // Live fields must also be persisted so they survive a restart.
    final allFields = {...liveFields, ...restartFields};
    if (allFields.isNotEmpty) {
      try {
        await writer.updateFields(allFields);
      } on StateError catch (e) {
        return errorResponse(500, 'BACKUP_FAILED', e.message);
      } on FileSystemException catch (e) {
        return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
      }
    }

    // Apply live fields immediately (runtime side-effects)
    for (final entry in liveFields.entries) {
      switch (entry.key) {
        case 'scheduling.heartbeat.enabled':
          final enabled = entry.value as bool;
          if (enabled) {
            heartbeat?.start();
          } else {
            heartbeat?.stop();
          }
          runtimeConfig.heartbeatEnabled = enabled;
        case 'workspace.git_sync.enabled':
          runtimeConfig.gitSyncEnabled = entry.value as bool;
        case 'workspace.git_sync.push_enabled':
          final enabled = entry.value as bool;
          if (gitSync != null) gitSync.pushEnabled = enabled;
          runtimeConfig.gitSyncPushEnabled = enabled;
      }
    }

    // Create/update restart.pending if needed
    if (restartFields.isNotEmpty) {
      writeRestartPending(dataDir, restartFields.keys.toList());
    }

    return jsonResponse(200, {
      'applied': liveFields.keys.toList(),
      'pendingRestart': restartFields.keys.toList(),
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
    final prompt = body['prompt'];
    final delivery = body['delivery'];

    if (name is! String || name.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"name" is required and must be a non-empty string');
    }
    if (schedule is! String || schedule.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"schedule" is required and must be a non-empty string');
    }
    if (prompt is! String || prompt.trim().isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', '"prompt" is required and must be a non-empty string');
    }
    if (delivery is! String || !const {'announce', 'webhook', 'none'}.contains(delivery)) {
      return errorResponse(400, 'INVALID_INPUT', '"delivery" must be one of: announce, webhook, none');
    }

    // Validate cron expression
    try {
      CronExpression.parse(schedule);
    } catch (_) {
      return errorResponse(400, 'INVALID_INPUT', 'Invalid cron expression: "$schedule"');
    }

    // Check uniqueness — read fresh from YAML (not startup snapshot).
    final currentJobs = await writer.readSchedulingJobs();
    if (currentJobs.any((j) => j['name'] == name)) {
      return errorResponse(409, 'CONFLICT', 'Job "$name" already exists');
    }

    final newJob = <String, dynamic>{
      'name': name,
      'schedule': schedule,
      'prompt': prompt,
      'delivery': delivery,
    };

    // Build updated array and write
    final updatedJobs = [
      ...currentJobs.map((j) => Map<String, dynamic>.from(j)),
      newJob,
    ];

    try {
      await writer.updateFields({'scheduling.jobs': updatedJobs});
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    writeRestartPending(dataDir, ['scheduling.jobs']);

    return jsonResponse(201, {
      'job': newJob,
      'pendingRestart': true,
    });
  });

  // PUT /api/scheduling/jobs/<name> — update existing job
  router.put('/api/scheduling/jobs/<name>', (Request request, String name) async {
    final body = await _parseJsonBody(request);
    if (body == null || body.isEmpty) {
      return errorResponse(400, 'INVALID_INPUT', 'Request body must be a non-empty JSON object');
    }

    // Read fresh from YAML (not startup snapshot) to avoid overwrite races.
    final currentJobs = await writer.readSchedulingJobs();
    final idx = currentJobs.indexWhere((j) => j['name'] == name);
    if (idx == -1) {
      return errorResponse(404, 'NOT_FOUND', 'Job "$name" not found');
    }

    // Validate changed fields
    if (body.containsKey('schedule')) {
      final schedule = body['schedule'];
      if (schedule is! String || schedule.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"schedule" must be a non-empty string');
      }
      try {
        CronExpression.parse(schedule);
      } catch (_) {
        return errorResponse(400, 'INVALID_INPUT', 'Invalid cron expression: "$schedule"');
      }
    }
    if (body.containsKey('prompt')) {
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', '"prompt" must be a non-empty string');
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

    return jsonResponse(200, {
      'job': job,
      'pendingRestart': true,
    });
  });

  // DELETE /api/scheduling/jobs/<name>
  router.delete('/api/scheduling/jobs/<name>', (Request request, String name) async {
    // Read fresh from YAML (not startup snapshot) to avoid overwrite races.
    final currentJobs = await writer.readSchedulingJobs();
    final idx = currentJobs.indexWhere((j) => j['name'] == name);
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

    return jsonResponse(200, {
      'deleted': true,
      'pendingRestart': true,
    });
  });

  // POST /api/system/restart — graceful restart
  router.post('/api/system/restart', (Request request) async {
    final rs = restartService;
    if (rs == null) {
      return errorResponse(
          503, 'RESTART_UNAVAILABLE', 'Restart service not configured');
    }
    if (rs.isRestarting) {
      return errorResponse(
          409, 'RESTART_IN_PROGRESS', 'Restart already in progress');
    }

    // Read current pending fields from restart.pending (if any).
    final pending = readRestartPending(dataDir);
    final fields = (pending?['fields'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        <String>[];

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
      return errorResponse(
          503, 'SSE_UNAVAILABLE', 'SSE broadcast not configured');
    }
    final controller = sse.subscribe();
    return Response.ok(
      controller.stream,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
    );
  });

  // --- Allowlist CRUD endpoints ---

  DmAccessController? resolveController(String type) {
    if (type == 'whatsapp') return whatsAppChannel?.dmAccess;
    if (type == 'signal') return signalChannel?.dmAccess;
    return null;
  }

  // GET /api/config/channels/<type>/dm-allowlist
  router.get('/api/config/channels/<type>/dm-allowlist', (Request request, String type) {
    final controller = resolveController(type);
    if (controller == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    return jsonResponse(200, {'allowlist': controller.allowlist.toList()});
  });

  // POST /api/config/channels/<type>/dm-allowlist
  router.post('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    final controller = resolveController(type);
    if (controller == null) {
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

    if (controller.allowlist.contains(entry)) {
      return errorResponse(409, 'CONFLICT', 'Entry "$entry" already in allowlist');
    }

    controller.addToAllowlist(entry);

    try {
      await writer.writeChannelAllowlist(type, 'dm_allowlist', controller.allowlist.toList());
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    return jsonResponse(200, {'added': true, 'allowlist': controller.allowlist.toList()});
  });

  // DELETE /api/config/channels/<type>/dm-allowlist
  router.delete('/api/config/channels/<type>/dm-allowlist', (Request request, String type) async {
    final controller = resolveController(type);
    if (controller == null) {
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

    if (!controller.allowlist.contains(entry)) {
      return errorResponse(404, 'NOT_FOUND', 'Entry "$entry" not in allowlist');
    }

    controller.removeFromAllowlist(entry);

    try {
      await writer.writeChannelAllowlist(type, 'dm_allowlist', controller.allowlist.toList());
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }

    return jsonResponse(200, {'removed': true, 'allowlist': controller.allowlist.toList()});
  });

  // --- Group Allowlist CRUD endpoints (restart-required) ---

  // GET /api/config/channels/<type>/group-allowlist
  router.get('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    if (type != 'whatsapp' && type != 'signal') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    final channel = type == 'whatsapp' ? whatsAppChannel : signalChannel;
    if (channel == null) {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    // Read from YAML to reflect pending (not-yet-restarted) changes.
    final entries = await writer.readChannelAllowlist(type, 'group_allowlist');
    return jsonResponse(200, {'allowlist': entries});
  });

  // POST /api/config/channels/<type>/group-allowlist
  router.post('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    if (type != 'whatsapp' && type != 'signal') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    final channel = type == 'whatsapp' ? whatsAppChannel : signalChannel;
    if (channel == null) {
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

    return jsonResponse(201, {'added': true, 'allowlist': updated});
  });

  // DELETE /api/config/channels/<type>/group-allowlist
  router.delete('/api/config/channels/<type>/group-allowlist', (Request request, String type) async {
    if (type != 'whatsapp' && type != 'signal') {
      return errorResponse(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    final channel = type == 'whatsapp' ? whatsAppChannel : signalChannel;
    if (channel == null) {
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

    final confirmed = controller.confirmPairing(code);
    if (!confirmed) {
      return errorResponse(404, 'NOT_FOUND', 'Pairing code not found or expired');
    }

    // Persist updated allowlist to YAML
    try {
      await writer.writeChannelAllowlist(type, 'dm_allowlist', controller.allowlist.toList());
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
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
    });
  });

  return router;
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
    } catch (_) {
      // Corrupted file — overwrite
    }
  }

  // Merge and deduplicate
  final merged = {...existingFields, ...fields}.toList();

  final json = jsonEncode({
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'fields': merged,
  });

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
  } catch (_) {
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
  } catch (_) {
    return null;
  }
}

