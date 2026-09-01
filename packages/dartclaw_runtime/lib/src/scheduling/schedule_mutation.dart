import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../restart_service.dart';
import 'cron_parser.dart';

final class ScheduleMutationRefusal {
  const new({required this.status, required this.code, required this.message, this.field});

  final int status;
  final String code;
  final String message;
  final String? field;
}

sealed class ScheduleMutationResult {
  const new();
}

final class ScheduleMutationApplied extends ScheduleMutationResult {
  const new(this.value);

  final Map<String, dynamic>? value;
}

final class ScheduleMutationRefused extends ScheduleMutationResult {
  const new(this.refusal);

  final ScheduleMutationRefusal refusal;
}

/// The single owner of every `scheduling.jobs` mutation.
///
/// Transport-neutral by construction: it validates, reads, writes and records
/// the restart marker, and answers with values. The HTTP scheduling handlers and
/// the `schedule_upsert` tool both consume it, which is what keeps the cron rule
/// and the write path from forking into two answers.
///
/// A written job does **not** run until the server restarts: [ScheduleService]
/// takes its job list at construction. Every write therefore records the
/// restart-pending marker, and every caller has to say so.
class ScheduleMutationService {
  final ConfigWriter _writer;
  final String _dataDir;

  new({required ConfigWriter writer, required String dataDir}) : _writer = writer, _dataDir = dataDir;

  /// Why [schedule] is not a usable cron expression, or `null` when it is.
  ///
  /// The parser rejects and never guesses, so this answers on its verdict alone.
  static String? cronRefusal(String schedule) {
    try {
      CronExpression.parse(schedule);
      return null;
    } catch (_) {
      return 'Invalid cron expression: "$schedule"';
    }
  }

  /// Index of the entry [id] names in [jobs], or `-1`.
  ///
  /// A job is addressed by `id` or by `name` on every surface, because both
  /// spellings are accepted in `scheduling.jobs`. [taskScoped] narrows the
  /// search to `type: task` entries, which is how the scheduled-task routes
  /// address their own half of the list.
  static int indexOfJob(List<Map<String, dynamic>> jobs, String id, {bool taskScoped = false}) =>
      jobs.indexWhere((job) => (!taskScoped || job['type'] == 'task') && (job['id'] == id || job['name'] == id));

  /// Reads `scheduling.jobs` fresh from YAML.
  ///
  /// Never the startup snapshot: it is stale the moment anything else writes,
  /// and every mutation here is a read-modify-write over the whole list.
  Future<List<Map<String, dynamic>>> readJobs() => _writer.readSchedulingJobs();

  Future<ScheduleMutationResult> createJob(Map<String, dynamic> body) async {
    final name = body['name'];
    final schedule = body['schedule'];
    if (name is! String || name.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"name" is required and must be a non-empty string', 'name');
    }
    if (schedule is! String || schedule.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"schedule" is required and must be a non-empty string', 'schedule');
    }
    final type = body['type'] as String? ?? 'prompt';
    if (type != 'prompt' && type != 'task') {
      return _refused(400, 'INVALID_INPUT', '"type" must be "prompt" or "task"', 'type');
    }
    if (type == 'prompt') {
      final delivery = body['delivery'];
      if (delivery is! String || !const {'announce', 'webhook', 'none'}.contains(delivery)) {
        return _refused(400, 'INVALID_INPUT', '"delivery" must be one of: announce, webhook, none', 'delivery');
      }
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        return _refused(400, 'INVALID_INPUT', '"prompt" is required for type: prompt', 'prompt');
      }
    } else {
      final refusal = taskPayloadRefusal(body['task']);
      if (refusal != null) return _refused(400, 'INVALID_INPUT', refusal, 'title');
    }
    final cronError = cronRefusal(schedule);
    if (cronError != null) return _refused(400, 'INVALID_INPUT', cronError, 'schedule');
    final jobs = await readJobs();
    if (indexOfJob(jobs, name) != -1) return _refused(409, 'CONFLICT', 'Job "$name" already exists', 'name');
    final job = <String, dynamic>{
      'name': name,
      'schedule': schedule,
      'type': type,
      if (type == 'prompt') 'delivery': body['delivery'],
      if (type == 'prompt') 'prompt': body['prompt'],
      if (type == 'task') 'task': taskPayloadWithoutCategory(body['task']),
      if (body['model'] != null) 'model': body['model'],
      if (body['effort'] != null) 'effort': body['effort'],
    };
    return _write([...jobs.map(Map<String, dynamic>.from), job], job);
  }

  Future<ScheduleMutationResult> updateJob(String name, Map<String, dynamic> body) async {
    final jobs = await readJobs();
    final index = indexOfJob(jobs, name);
    if (index == -1) return _refused(404, 'NOT_FOUND', 'Job "$name" not found');
    final current = jobs[index];
    final type = body['type'] as String? ?? current['type'] as String? ?? 'prompt';
    if (body.containsKey('schedule')) {
      final schedule = body['schedule'];
      if (schedule is! String || schedule.trim().isEmpty) {
        return _refused(400, 'INVALID_INPUT', '"schedule" must be a non-empty string', 'schedule');
      }
      final refusal = cronRefusal(schedule);
      if (refusal != null) return _refused(400, 'INVALID_INPUT', refusal, 'schedule');
    }
    if (body.containsKey('type') && type != 'prompt' && type != 'task') {
      return _refused(400, 'INVALID_INPUT', '"type" must be "prompt" or "task"', 'type');
    }
    if (body.containsKey('prompt')) {
      if (type != 'prompt') return _refused(400, 'INVALID_INPUT', '"prompt" is only valid for type: prompt', 'prompt');
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        return _refused(400, 'INVALID_INPUT', '"prompt" must be a non-empty string', 'prompt');
      }
    }
    if (body.containsKey('task')) {
      if (type != 'task') return _refused(400, 'INVALID_INPUT', '"task" is only valid for type: task');
      final refusal = taskPayloadRefusal(body['task']);
      if (refusal != null) return _refused(400, 'INVALID_INPUT', refusal);
    }
    if (body.containsKey('delivery')) {
      final delivery = body['delivery'];
      if (delivery is! String || !const {'announce', 'webhook', 'none'}.contains(delivery)) {
        return _refused(400, 'INVALID_INPUT', '"delivery" must be one of: announce, webhook, none', 'delivery');
      }
    }
    final updated = jobs.map(Map<String, dynamic>.from).toList();
    final job = updated[index];
    for (final entry in body.entries) {
      if (entry.key == 'task') {
        job['task'] = taskPayloadWithoutCategory(entry.value);
      } else if (entry.key != 'name') {
        job[entry.key] = entry.value;
      }
    }
    return _write(updated, job);
  }

  Future<ScheduleMutationResult> deleteJob(String name) async => _delete(name, taskScoped: false);

  Future<ScheduleMutationResult> createTask(Map<String, dynamic> body) async {
    final id = body['id'];
    final schedule = body['schedule'];
    final title = body['title'];
    final description = body['description'];
    if (id is! String || id.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"id" is required and must be a non-empty string', 'id');
    }
    if (schedule is! String || schedule.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"schedule" is required and must be a non-empty string', 'schedule');
    }
    if (title is! String || title.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"title" is required and must be a non-empty string', 'title');
    }
    if (description is! String || description.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"description" is required and must be a non-empty string', 'description');
    }
    final categoryRefusal = retiredTaskCategoryRefusal([body['type']]);
    if (categoryRefusal != null) return _refused(400, 'INVALID_INPUT', categoryRefusal.toString(), 'type');
    final cronError = cronRefusal(schedule);
    if (cronError != null) return _refused(400, 'INVALID_INPUT', cronError, 'schedule');
    final jobs = await readJobs();
    if (indexOfJob(jobs, id, taskScoped: true) != -1) {
      return _refused(409, 'CONFLICT', 'Scheduled task "$id" already exists', 'id');
    }
    final job = <String, dynamic>{
      'id': id,
      'type': 'task',
      'schedule': schedule,
      'enabled': body['enabled'] ?? true,
      'task': <String, dynamic>{
        'title': title,
        'description': description,
        if (body['acceptanceCriteria'] is String && (body['acceptanceCriteria'] as String).isNotEmpty)
          'acceptance_criteria': body['acceptanceCriteria'],
        if (body['autoStart'] != null) 'auto_start': body['autoStart'],
      },
    };
    return _write([...jobs.map(Map<String, dynamic>.from), job], job);
  }

  Future<ScheduleMutationResult> updateTask(String id, Map<String, dynamic> body) async {
    final jobs = await readJobs();
    final index = indexOfJob(jobs, id, taskScoped: true);
    if (index == -1) return _refused(404, 'NOT_FOUND', 'Scheduled task "$id" not found');
    if (body.containsKey('schedule')) {
      final schedule = body['schedule'];
      if (schedule is! String || schedule.trim().isEmpty) {
        return _refused(400, 'INVALID_INPUT', '"schedule" must be a non-empty string', 'schedule');
      }
      final refusal = cronRefusal(schedule);
      if (refusal != null) return _refused(400, 'INVALID_INPUT', refusal, 'schedule');
    }
    final categoryRefusal = retiredTaskCategoryRefusal([body['type']]);
    if (categoryRefusal != null) return _refused(400, 'INVALID_INPUT', categoryRefusal.toString(), 'type');
    final updated = jobs.map(Map<String, dynamic>.from).toList();
    final job = updated[index];
    if (body.containsKey('schedule')) job['schedule'] = body['schedule'];
    if (body.containsKey('enabled')) job['enabled'] = body['enabled'];
    final task = job['task'] is Map ? Map<String, dynamic>.from(job['task'] as Map) : <String, dynamic>{};
    if (body.containsKey('title')) task['title'] = body['title'];
    if (body.containsKey('description')) task['description'] = body['description'];
    if (body.containsKey('acceptanceCriteria')) task['acceptance_criteria'] = body['acceptanceCriteria'];
    if (body.containsKey('autoStart')) task['auto_start'] = body['autoStart'];
    job['task'] = task;
    return _write(updated, job);
  }

  Future<ScheduleMutationResult> deleteTask(String id) async => _delete(id, taskScoped: true);

  Future<ScheduleMutationResult> _delete(String id, {required bool taskScoped}) async {
    final jobs = await readJobs();
    final index = indexOfJob(jobs, id, taskScoped: taskScoped);
    if (index == -1) {
      final noun = taskScoped ? 'Scheduled task' : 'Job';
      return _refused(404, 'NOT_FOUND', '$noun "$id" not found');
    }
    final updated = jobs.map(Map<String, dynamic>.from).toList()..removeAt(index);
    return _write(updated, null);
  }

  Future<ScheduleMutationResult> _write(List<Map<String, dynamic>> jobs, Map<String, dynamic>? value) async {
    try {
      await commit(jobs);
      markRestartPending();
      return ScheduleMutationApplied(value);
    } on StateError catch (error) {
      return _refused(500, 'BACKUP_FAILED', error.message);
    } on FileSystemException catch (error) {
      return _refused(500, 'WRITE_FAILED', 'Config write failed: ${error.message}');
    }
  }

  ScheduleMutationResult _refused(int status, String code, String message, [String? field]) =>
      ScheduleMutationRefused(ScheduleMutationRefusal(status: status, code: code, message: message, field: field));

  /// Why [task] is not a usable `type: task` payload, or `null` when it is.
  ///
  /// The nested-task shape a `scheduling.jobs` entry must carry, shared so the
  /// job route and the tool cannot accept different payloads. An entry that
  /// fails this is dropped at the next boot with a log warning, which is a
  /// worse answer than a refusal at the write.
  static String? taskPayloadRefusal(Object? task) {
    if (task is! Map) return '"task" object is required for type: task';
    final title = task['title'];
    final description = task['description'];
    if (title is! String || title.trim().isEmpty) return '"task.title" is required';
    if (description is! String || description.trim().isEmpty) return '"task.description" is required';
    final refusal = retiredTaskCategoryRefusal([task['task_type'], task['type']]);
    if (refusal != null) return refusal.toString();
    return null;
  }

  /// Returns a writable task payload with retired category keys omitted.
  static Map<String, dynamic> taskPayloadWithoutCategory(Object? task) => Map<String, dynamic>.from(task as Map)
    ..remove('type')
    ..remove('task_type');

  /// Writes [jobs] as the whole `scheduling.jobs` list.
  ///
  /// Throws whatever [ConfigWriter.updateFields] throws — a `StateError` for a
  /// failed backup, a `FileSystemException` for a failed write — so a caller
  /// keeps its own mapping of those two failures. Deliberately does **not**
  /// record the restart marker: a marker write that fails after the config
  /// write succeeded would otherwise be reported as a failed config write.
  Future<void> commit(List<Map<String, dynamic>> jobs) => _writer.updateFields({'scheduling.jobs': jobs});

  /// Records that `scheduling.jobs` changed and takes effect at the next
  /// restart. Called by the caller after [commit] succeeds.
  void markRestartPending() => writeRestartPending(_dataDir, ['scheduling.jobs']);
}
