import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';

import '../scheduling/schedule_mutation.dart';
import '../scheduling/schedule_service.dart';
import '../scheduling/scheduled_task_runner.dart';
import 'tool_schema.dart';

/// MCP tool that creates or updates a scheduled job through the shared
/// scheduling-mutation seam.
///
/// Performs no validation of its own beyond its declared input contract: the
/// schedule rule and the config write are the seam's, exactly as for the web
/// API. The seam loads what it wrote before returning, so the result reports
/// whether the running scheduler holds the job rather than promising a restart.
class ScheduleUpsertTool implements McpTool {
  new({required ScheduleMutationService mutations, ScheduleService? schedules})
    : _mutations = mutations,
      _schedules = schedules;

  final ScheduleMutationService _mutations;
  final ScheduleService? _schedules;

  @override
  String get name => 'schedule_upsert';

  @override
  String get description =>
      'Create or update a scheduled job. It runs from the moment this call returns — no restart. Pass "schedule" for '
      'a recurring job or "at" for a one-time job, never both. List what is configured and what is running with '
      'schedule_list first.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'id': {'type': 'string', 'description': 'Job identifier; an existing job with this id is replaced.'},
      'schedule': {'type': 'string', 'description': 'Five-field cron expression, e.g. "0 9 * * 1".'},
      'at': {
        'type': 'string',
        'description':
            'ISO-8601 instant for a one-time job, e.g. "2026-09-02T15:00:00". Must be in the future. The job '
            'removes itself once it has fired. Mutually exclusive with schedule.',
      },
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
    const ['id', 'type'],
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

    final id = args['id'] as String;
    if (_mutations.reservedJobIds.contains(id)) {
      return toolError('conflict', 'Job "$id" is a built-in job and cannot be edited through schedule_upsert', {
        'id': id,
      });
    }

    // The schedule/at rule is the seam's, so the tool and the jobs API cannot
    // accept different instants or different cron expressions.
    final schedule = _mutations.resolveSchedule(args['schedule'], args['at']);
    if (schedule.refusal != null) {
      return toolError('invalid_schedule', schedule.refusal!, {'field': schedule.field});
    }

    // Only what the call actually supplied: an omitted `delivery` must not be
    // written as `none` over a stored `webhook`, and the loader applies its own
    // default for an entry that carries none.
    final job = <String, dynamic>{
      'id': id,
      'schedule': schedule.value,
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
      await _mutations.commitAndApply(jobs);
    } on StateError catch (error) {
      return toolError('write_failed', 'Config backup failed: ${error.message}', {'id': id});
    } on FileSystemException catch (error) {
      return toolError('write_failed', 'Config write failed: ${error.message}', {'id': id});
    }
    // A `type: task` entry reaches the scheduler under the runner's job id, so
    // asking about the entry id would report every task upsert as not loaded.
    final loadedId = type == 'task' ? ScheduledTaskRunner.jobIdForDefinition(id) : id;
    return toolJson({
      'id': id,
      'created': created,
      'schedule': schedule.value,
      'loaded': _schedules?.hasJob(loadedId) ?? false,
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
      'List scheduled jobs: what is configured, what the running server actually loaded, and what is paused. '
      'Built-in jobs are listed too and cannot be edited through schedule_upsert.';

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
        // A written job is loaded before its write returns, so a configured
        // entry the scheduler does not hold is one it could not compose.
        if (entry == null && _schedules != null)
          'note': 'Written to config but not loaded; check the server log for the reason it was skipped.',
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
