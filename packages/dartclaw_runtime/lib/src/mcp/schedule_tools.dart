import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';

import '../scheduling/schedule_mutation.dart';
import '../scheduling/schedule_service.dart';
import 'tool_schema.dart';

/// What every successful [ScheduleUpsertTool] call tells the model to pass on.
///
/// `ScheduleService` takes its job list at construction, so a written job does
/// not fire until the server restarts. A result that reads as "scheduled" is a
/// lie the owner acts on.
const _restartNotice = 'Written to config. The job does not run until the server restarts.';

/// MCP tool that creates or updates a scheduled job through the shared
/// scheduling-mutation seam.
///
/// Performs no validation of its own beyond its declared input contract: cron
/// validation and the config write are the seam's, exactly as for the web API.
class ScheduleUpsertTool implements McpTool {
  new({required ScheduleMutationService mutations}) : _mutations = mutations;

  final ScheduleMutationService _mutations;

  @override
  String get name => 'schedule_upsert';

  @override
  String get description =>
      'Create or update a scheduled job. $_restartNotice List what is configured and what is running with '
      'schedule_list first.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'id': {'type': 'string', 'description': 'Job identifier; an existing job with this id is replaced.'},
      'schedule': {'type': 'string', 'description': 'Five-field cron expression, e.g. "0 9 * * 1".'},
      'type': {
        'type': 'string',
        'enum': const ['prompt', 'task'],
      },
      'prompt': {'type': 'string', 'description': 'Prompt to run each fire. Required for type: prompt.'},
      'task': {
        'type': 'object',
        'description': 'Task to create each fire, with title and description. Required for type: task.',
      },
      'delivery': {
        'type': 'string',
        'enum': const ['announce', 'webhook', 'none'],
      },
      'model': {'type': 'string', 'description': 'Model override for this job.'},
      'effort': {'type': 'string', 'description': 'Effort override for this job.'},
    },
    const ['id', 'schedule', 'type'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final type = args['type'] as String;
    // The payload each type requires is part of this tool's declared input
    // contract, so the model meets it as an argument refusal rather than as a
    // job the next server start drops with a log warning nobody reads. An
    // argument belonging to the other type fails the call rather than being
    // dropped: silently discarding a model-supplied value is what ADR-054
    // forbids.
    final shapeRefusal = switch (type) {
      'prompt' when args['prompt'] == null => 'prompt is required when type is prompt',
      'prompt' when args['task'] != null => 'task is only valid when type is task',
      'task' when args['prompt'] != null => 'prompt is only valid when type is prompt',
      'task' when args['delivery'] != null => 'delivery is only valid when type is prompt',
      // The nested-task shape is the seam's, so this tool and the job route
      // cannot accept different payloads.
      'task' => ScheduleMutationService.taskPayloadRefusal(args['task']),
      _ => null,
    };
    if (shapeRefusal != null) return toolError('invalid_request', shapeRefusal);

    final schedule = args['schedule'] as String;
    final cronRefusal = ScheduleMutationService.cronRefusal(schedule);
    if (cronRefusal != null) return toolError('invalid_cron', cronRefusal, {'schedule': schedule});

    final id = args['id'] as String;
    // Only what the call actually supplied: an omitted `delivery` must not be
    // written as `none` over a stored `webhook`, and the loader applies its own
    // default for an entry that carries none.
    final job = <String, dynamic>{
      'id': id,
      'schedule': schedule,
      'type': type,
      if (args['prompt'] != null) 'prompt': args['prompt'],
      if (args['delivery'] != null) 'delivery': args['delivery'],
      if (args['task'] != null) 'task': ScheduleMutationService.taskPayloadWithoutCategory(args['task']),
      if (args['model'] != null) 'model': args['model'],
      if (args['effort'] != null) 'effort': args['effort'],
    };

    final jobs = [for (final entry in await _mutations.readJobs()) Map<String, dynamic>.from(entry)];
    final existing = ScheduleMutationService.indexOfJob(jobs, id);
    final created = existing == -1;
    if (created) {
      jobs.add(job);
    } else {
      // Merged, not replaced — the same shape `PUT /api/scheduling/jobs/<name>`
      // applies. Replacing would drop every operator-set key this tool cannot
      // express (`enabled`, `webhook_url`, `retry.*`, `allowed_tools`).
      jobs[existing] = {...jobs[existing], ...job};
    }

    try {
      await _mutations.commit(jobs);
    } on StateError catch (error) {
      return toolError('write_failed', 'Config backup failed: ${error.message}', {'id': id});
    } on FileSystemException catch (error) {
      return toolError('write_failed', 'Config write failed: ${error.message}', {'id': id});
    }
    _mutations.markRestartPending();
    return toolJson({
      'id': id,
      'created': created,
      'schedule': schedule,
      'pending_restart': true,
      'note': _restartNotice,
    });
  }
}

/// MCP tool that answers what is scheduled, when it fires, and whether the
/// running server has it loaded.
///
/// Joins two sources because neither alone answers the question: the running
/// [ScheduleService] knows what it loaded and what is paused but carries no
/// config shape, and `scheduling.jobs` carries the cron expression and shape but
/// knows nothing about what is running.
class ScheduleListTool implements McpTool {
  new({required ScheduleMutationService mutations, required ScheduleService? schedules})
    : _mutations = mutations,
      _schedules = schedules;

  final ScheduleMutationService _mutations;
  final ScheduleService? _schedules;

  @override
  String get name => 'schedule_list';

  @override
  String get description =>
      'List scheduled jobs: what is configured, what the running server actually loaded, and what is waiting for a '
      'restart. Built-in jobs are listed too and cannot be edited through schedule_upsert.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(const {}, const []);

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final configured = await _mutations.readJobs();
    final loaded = {for (final entry in _schedules?.entries ?? const <LoadedScheduleEntry>[]) entry.id: entry};

    final rows = <Map<String, Object?>>[];
    for (final job in configured) {
      final id = (job['id'] ?? job['name']) as String? ?? '';
      final entry = loaded[id];
      rows.add({
        'id': id,
        'schedule': job['schedule'],
        'type': job['type'] ?? 'prompt',
        'source': 'config',
        'loaded': entry != null,
        'paused': entry?.paused ?? false,
        'editable': true,
        if (entry == null) 'note': 'Written to config but not loaded; it runs after the next server restart.',
      });
    }
    // A loaded job with no config entry is built-in: the runtime registers it
    // itself, so `scheduling.jobs` cannot address it and schedule_upsert cannot
    // edit it.
    final configuredIds = {for (final job in configured) (job['id'] ?? job['name']) as String? ?? ''};
    for (final entry in loaded.values.where((entry) => !configuredIds.contains(entry.id))) {
      rows.add({
        'id': entry.id,
        'schedule': entry.cronExpression,
        'type': 'prompt',
        'source': 'built-in',
        'loaded': true,
        'paused': entry.paused,
        'editable': false,
      });
    }
    return toolJson({'jobs': rows, 'scheduler_running': _schedules != null});
  }
}
