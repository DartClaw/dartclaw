import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:uuid/uuid.dart';

import 'cron_parser.dart';
import 'pending_schedule_change.dart';

final _scheduleMutationLock = RepoLock();

/// Thrown by [ScheduleMutationService.commitAndApply] when a write would add,
/// remove or change a `type: shell` entry.
///
/// The kind is file-only by design: it runs an operator-declared command with
/// no model turn and no guard over it, so a chat-, API- or tool-reachable write
/// would be the command execution that rule exists to prevent. One authority
/// refuses it — the point both the seam's own CRUD and the tool's merge path
/// pass through — rather than two surfaces agreeing on a check.
final class ShellJobWriteRefused implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => message;
}

final class _ScheduleJobsApplyFailed implements Exception {
  const new(this.cause);

  final Object cause;
}

final class _PendingRemovalFailed implements Exception {
  const new(this.cause);

  final Object cause;
}

final class _SettlementRecoveryFailed implements Exception {
  const new(this.message);

  final String message;
}

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

/// A validated write held back for operator approval instead of committed.
///
/// Only [ScheduleMutationService.upsertJob] answers this, and only under
/// [ScheduleMutationApproval.operator]; every other operation commits.
final class ScheduleMutationParked extends ScheduleMutationResult {
  const new(this.changeId);

  final String changeId;
}

/// What an upsert did: its seam result, and whether the id was new.
typedef ScheduleUpsertOutcome = ({ScheduleMutationResult result, bool created});

/// What a request's `schedule` / `at` pair resolves to: the `schedule` value the
/// job entry must carry, or the reason the pair cannot be honoured.
typedef ResolvedSchedule = ({Object? value, String? refusal, String? field});

/// The single owner of every `scheduling.jobs` mutation.
///
/// Transport-neutral by construction: it validates, reads, writes and loads, and
/// answers with values. The HTTP scheduling handlers, the scheduling page and
/// the `schedule_upsert` tool all consume it, which is what keeps the cron rule
/// and the write path from forking into two answers.
///
/// A written job is live before the caller is answered: every write commits and
/// then awaits the injected applier, which hands the running [ScheduleService]
/// the jobs the written file declares. No restart marker is recorded for
/// `scheduling.jobs` and no caller may claim one is needed.
///
/// The one exception is a model-originated [upsertJob] under
/// [ScheduleMutationApproval.operator]: the validated body is parked in the
/// pending store and committed only by [approve], through the same write path.
/// The mode is a constructor argument from the composition root, never a
/// caller value, which is what keeps the gate deterministic (ADR-054).
class ScheduleMutationService {
  final ConfigWriter _writer;
  final Future<void> Function()? _applyJobs;
  final Set<String> Function()? _reservedJobIds;
  final DateTime Function() _now;
  final ScheduleMutationApproval _approval;
  final PendingScheduleChangeStore? _pendingChanges;

  Future<T> _synchronized<T>(Future<T> Function() action) => _scheduleMutationLock.acquire(_writer.configPath, action);

  /// [applyJobs] loads the written jobs into the running scheduler and
  /// [reservedJobIds] answers which ids the runtime already owns. Both are
  /// resolved lazily by the composition root, because the scheduler this seam
  /// feeds is constructed after the surfaces that write through it.
  ///
  /// [approval] gates [upsertJob] alone and requires [pendingChanges] when it
  /// is `operator`; a surface that only settles parked changes passes the store
  /// and no mode.
  new({
    required ConfigWriter writer,
    Future<void> Function()? applyJobs,
    Set<String> Function()? reservedJobIds,
    DateTime Function()? now,
    ScheduleMutationApproval approval = ScheduleMutationApproval.none,
    PendingScheduleChangeStore? pendingChanges,
  }) : _writer = writer,
       _applyJobs = applyJobs,
       _reservedJobIds = reservedJobIds,
       _now = now ?? DateTime.now,
       _approval = approval,
       _pendingChanges = pendingChanges {
    if (_approval == ScheduleMutationApproval.operator && _pendingChanges == null) {
      throw ArgumentError('approval: operator requires a pending-change store');
    }
  }

  /// The parked changes this seam can settle, oldest first.
  List<PendingScheduleChange> get pendingChanges => _pendingChanges?.values ?? const [];

  /// The job ids the runtime registered itself, which no write may claim.
  Set<String> get reservedJobIds => _reservedJobIds?.call() ?? const {};

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

  /// Resolves the `schedule` a job entry must carry from a request's
  /// [schedule] / [at] pair.
  ///
  /// Exactly one is required: [schedule] a five-field cron expression, [at] an
  /// ISO-8601 instant still ahead of this seam's clock. A one-time request
  /// stores `{type: once, at: <the supplied text>}` — the caller's own instant,
  /// never a reformatted one.
  ResolvedSchedule resolveSchedule(Object? schedule, Object? at) {
    if (schedule != null && at != null) {
      return (value: null, refusal: 'Pass exactly one of "schedule" and "at", not both', field: 'at');
    }
    if (schedule == null && at == null) {
      return (
        value: null,
        refusal: 'One of "schedule" (cron expression) and "at" (one-time instant) is required',
        field: 'schedule',
      );
    }
    if (at != null) {
      if (at is! String || at.trim().isEmpty) {
        return (value: null, refusal: '"at" must be a non-empty ISO-8601 instant', field: 'at');
      }
      final refusal = instantRefusal(at);
      if (refusal != null) return (value: null, refusal: refusal, field: 'at');
      return (value: <String, dynamic>{'type': 'once', 'at': at}, refusal: null, field: null);
    }
    if (schedule is! String || schedule.trim().isEmpty) {
      return (value: null, refusal: '"schedule" must be a non-empty string', field: 'schedule');
    }
    final cronError = cronRefusal(schedule);
    if (cronError != null) return (value: null, refusal: cronError, field: 'schedule');
    return (value: schedule, refusal: null, field: null);
  }

  /// Why [at] is not a one-time instant this seam can still honour, or `null`
  /// when it parses and lies ahead of the seam's clock.
  ///
  /// The one future-instant rule: [resolveSchedule] applies it to a request and
  /// [approve] re-applies it to a parked `{type: once, at}` body, so the two
  /// cannot answer differently.
  String? instantRefusal(String at) {
    final instant = DateTime.tryParse(at);
    if (instant == null) return 'Invalid "at" instant: "$at"';
    if (!instant.isAfter(_now())) return '"at" must be later than now: "$at"';
    return null;
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

  Future<ScheduleMutationResult> createJob(Map<String, dynamic> body) => _synchronized(() => _createJob(body));

  Future<ScheduleMutationResult> _createJob(Map<String, dynamic> body) async {
    final name = body['name'];
    if (name is! String || name.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"name" is required and must be a non-empty string', 'name');
    }
    final reserved = _reservedRefusal(name, noun: 'Job', field: 'name');
    if (reserved != null) return reserved;
    final resolved = resolveSchedule(body['schedule'], body['at']);
    if (resolved.refusal != null) return _refused(400, 'INVALID_INPUT', resolved.refusal!, resolved.field);
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
    final jobs = await readJobs();
    if (indexOfJob(jobs, name) != -1) return _refused(409, 'CONFLICT', 'Job "$name" already exists', 'name');
    final job = <String, dynamic>{
      'name': name,
      'schedule': resolved.value,
      'type': type,
      if (type == 'prompt') 'delivery': body['delivery'],
      if (type == 'prompt') 'prompt': body['prompt'],
      if (type == 'task') 'task': taskPayloadWithoutCategory(body['task']),
      if (body['model'] != null) 'model': body['model'],
      if (body['effort'] != null) 'effort': body['effort'],
    };
    return _write([...jobs.map(Map<String, dynamic>.from), job], job);
  }

  Future<ScheduleMutationResult> updateJob(String name, Map<String, dynamic> body) =>
      _synchronized(() => _updateJob(name, body));

  Future<ScheduleMutationResult> _updateJob(String name, Map<String, dynamic> body) async {
    final jobs = await readJobs();
    final index = indexOfJob(jobs, name);
    if (index == -1) return _refused(404, 'NOT_FOUND', 'Job "$name" not found');
    final current = jobs[index];
    final type = body['type'] as String? ?? current['type'] as String? ?? 'prompt';
    final touchesSchedule = body.containsKey('schedule') || body.containsKey('at');
    Object? scheduleValue;
    if (touchesSchedule) {
      final resolved = resolveSchedule(body['schedule'], body['at']);
      if (resolved.refusal != null) return _refused(400, 'INVALID_INPUT', resolved.refusal!, resolved.field);
      scheduleValue = resolved.value;
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
      } else if (entry.key != 'name' && entry.key != 'schedule' && entry.key != 'at') {
        job[entry.key] = entry.value;
      }
    }
    if (touchesSchedule) job['schedule'] = scheduleValue;
    return _write(updated, job);
  }

  Future<ScheduleMutationResult> deleteJob(String name) => _synchronized(() => _delete(name, taskScoped: false));

  /// Creates or replaces the entry [job]'s `id` names, the `schedule_upsert`
  /// contract.
  ///
  /// [job] is the body the caller already validated against its own declared
  /// contract, `schedule` resolved through [resolveSchedule]. An existing entry
  /// is merged, not replaced, so operator-set keys the caller cannot express
  /// survive. Under [ScheduleMutationApproval.operator] the caller's body is
  /// parked as supplied under [requester] — host-owned provenance, never a
  /// caller argument — and the result is [ScheduleMutationParked]; the merge
  /// happens once, at commit, so an operator edit made while the change waits
  /// is not reverted by approving it. Otherwise it commits and applies like
  /// every other write. A body that could never commit — one naming a
  /// file-only `type: shell` entry — is refused here under either mode, by the
  /// same predicate [commitAndApply] applies.
  Future<ScheduleUpsertOutcome> upsertJob(Map<String, dynamic> job, {required String requester}) {
    if (_approval == ScheduleMutationApproval.operator) {
      return _pendingChanges!.synchronized(() => _synchronized(() => _upsertJob(job, requester: requester)));
    }
    return _synchronized(() => _upsertJob(job, requester: requester));
  }

  Future<ScheduleUpsertOutcome> _upsertJob(Map<String, dynamic> job, {required String requester}) async {
    final id = job['id'] as String;
    final reserved = _reservedRefusal(id, noun: 'Job', field: 'id');
    if (reserved != null) return (result: reserved, created: false);
    final jobs = await readJobs();
    final created = indexOfJob(jobs, id) == -1;
    final merged = _mergeUpsert(jobs, job);
    final shellRefusal = _shellWriteRefusal(jobs, merged.jobs);
    if (shellRefusal != null) return (result: _refused(400, 'INVALID_INPUT', shellRefusal), created: created);
    if (_approval == ScheduleMutationApproval.operator) {
      final change = PendingScheduleChange(
        changeId: const Uuid().v4(),
        jobId: id,
        kind: created ? PendingChangeKind.created : PendingChangeKind.replaced,
        job: job,
        requester: requester,
        requestedAt: _now().toUtc(),
      );
      try {
        await _pendingChanges!.add(change);
      } on PendingScheduleChangeCapacityExceeded catch (error) {
        return (result: _refused(429, 'PENDING_QUEUE_FULL', error.toString()), created: created);
      } on FileSystemException catch (error) {
        return (
          result: _refused(500, 'WRITE_FAILED', 'Pending change write failed: ${error.message}'),
          created: created,
        );
      }
      return (result: ScheduleMutationParked(change.changeId), created: created);
    }
    return (result: await _write(merged.jobs, merged.job), created: created);
  }

  /// Commits the parked change [changeId] through the same write path an
  /// unparked upsert takes, then drops it from the store.
  ///
  /// The body is not re-validated — the seam accepted it when it parked it.
  /// Only the two conditions host state can have changed underneath are
  /// re-checked: the id becoming a built-in, and a one-time instant passing. A
  /// refusal before the commit leaves the change pending for an explicit
  /// reject. Settlement is serialized by the store so exactly one operator
  /// decision can act on a record. If pending removal fails after the config
  /// commit, the previous `scheduling.jobs` value is restored before runtime
  /// is reloaded; failures in that compensation are reported explicitly.
  Future<ScheduleMutationResult> approve(String changeId) async {
    final store = _pendingChanges;
    if (store == null) return _refused(404, 'NOT_FOUND', 'Pending change "$changeId" not found');
    return store.synchronized(() async {
      final change = store.byId(changeId);
      if (change == null) return _refused(404, 'NOT_FOUND', 'Pending change "$changeId" not found');
      return _synchronized(() async {
        final reserved = _reservedRefusal(change.jobId, noun: 'Job', field: 'id');
        if (reserved != null) return reserved;
        if (change.job['schedule'] case {'type': 'once', 'at': final String at}) {
          final refusal = instantRefusal(at);
          if (refusal != null) return _refused(400, 'INVALID_INPUT', refusal, 'at');
        }
        final merged = _mergeUpsert(await readJobs(), change.job);
        return _write(
          merged.jobs,
          merged.job,
          afterCommit: () => store.remove(changeId),
          recoverAfterCommitFailure: _restoreAfterSettlementFailure,
        );
      });
    });
  }

  /// Discards the parked change [changeId]; nothing is written to config.
  Future<ScheduleMutationResult> reject(String changeId) async {
    final store = _pendingChanges;
    if (store == null) return _refused(404, 'NOT_FOUND', 'Pending change "$changeId" not found');
    return store.synchronized(() async {
      final change = store.byId(changeId);
      if (change == null) return _refused(404, 'NOT_FOUND', 'Pending change "$changeId" not found');
      try {
        await store.remove(changeId);
      } on FileSystemException catch (error) {
        return _refused(500, 'WRITE_FAILED', 'Pending change write failed: ${error.message}');
      }
      return ScheduleMutationApplied(change.job);
    });
  }

  Future<void> _restoreAfterSettlementFailure(List<Map<String, dynamic>> previousJobs, Object removeError) async {
    Object? recoveryError;
    try {
      await commitAndApply(previousJobs);
    } catch (error) {
      recoveryError = error;
    }
    if (recoveryError == null) throw _PendingRemovalFailed(removeError);

    if (recoveryError case _ScheduleJobsApplyFailed(:final cause)) {
      throw _SettlementRecoveryFailed(
        'pending removal failed: $removeError; config was restored but runtime reload failed: $cause',
      );
    }

    Object? reloadError;
    try {
      await _applyJobs?.call();
    } catch (error) {
      reloadError = error;
    }
    throw _SettlementRecoveryFailed(
      [
        'pending removal failed: $removeError',
        'config rollback failed: $recoveryError',
        if (reloadError != null) 'runtime reload failed: $reloadError',
      ].join('; '),
    );
  }

  /// The whole list with [job] merged over the entry its id names, or appended.
  static ({List<Map<String, dynamic>> jobs, Map<String, dynamic> job}) _mergeUpsert(
    List<Map<String, dynamic>> stored,
    Map<String, dynamic> job,
  ) {
    final jobs = stored.map(Map<String, dynamic>.from).toList();
    final index = indexOfJob(jobs, job['id'] as String);
    if (index == -1) {
      jobs.add(job);
      return (jobs: jobs, job: job);
    }
    jobs[index] = {...jobs[index], ...job};
    return (jobs: jobs, job: jobs[index]);
  }

  Future<ScheduleMutationResult> createTask(Map<String, dynamic> body) => _synchronized(() => _createTask(body));

  Future<ScheduleMutationResult> _createTask(Map<String, dynamic> body) async {
    final id = body['id'];
    final schedule = body['schedule'];
    final title = body['title'];
    final description = body['description'];
    if (id is! String || id.trim().isEmpty) {
      return _refused(400, 'INVALID_INPUT', '"id" is required and must be a non-empty string', 'id');
    }
    final reserved = _reservedRefusal(id, noun: 'Scheduled task', field: 'id');
    if (reserved != null) return reserved;
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

  Future<ScheduleMutationResult> updateTask(String id, Map<String, dynamic> body) =>
      _synchronized(() => _updateTask(id, body));

  Future<ScheduleMutationResult> _updateTask(String id, Map<String, dynamic> body) async {
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

  Future<ScheduleMutationResult> deleteTask(String id) => _synchronized(() => _delete(id, taskScoped: true));

  /// Drops [ids] from `scheduling.jobs`, leaving every other entry untouched.
  ///
  /// The persistence half of an unload the runtime has already performed — the
  /// caller has composed the surviving job list itself — so this commits without
  /// re-applying.
  Future<void> removeJobs(Iterable<String> ids) => _synchronized(() => _removeJobs(ids));

  Future<void> _removeJobs(Iterable<String> ids) async {
    final drop = ids.toSet();
    final jobs = await readJobs();
    final remaining = [
      for (final job in jobs)
        if (!drop.contains(job['id'] ?? job['name'])) Map<String, dynamic>.from(job),
    ];
    if (remaining.length == jobs.length) return;
    await commit(remaining);
  }

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

  Future<ScheduleMutationResult> _write(
    List<Map<String, dynamic>> jobs,
    Map<String, dynamic>? value, {
    Future<void> Function()? afterCommit,
    Future<void> Function(List<Map<String, dynamic>> previousJobs, Object error)? recoverAfterCommitFailure,
  }) async {
    try {
      await commitAndApply(jobs, afterCommit: afterCommit, recoverAfterCommitFailure: recoverAfterCommitFailure);
      return ScheduleMutationApplied(value);
    } on _PendingRemovalFailed catch (error) {
      return _refused(
        500,
        'WRITE_FAILED',
        'Approval was not applied because the pending change could not be removed; scheduling.jobs was restored: '
            '${error.cause}',
      );
    } on _SettlementRecoveryFailed catch (error) {
      return _refused(500, 'SETTLEMENT_FAILED', 'Approval settlement could not be recovered: ${error.message}');
    } on _ScheduleJobsApplyFailed catch (error) {
      return _refused(500, 'APPLY_FAILED', 'Scheduling jobs were written but could not be loaded: ${error.cause}');
    } on ShellJobWriteRefused catch (error) {
      return _refused(400, 'INVALID_INPUT', error.message);
    } on StateError catch (error) {
      return _refused(500, 'BACKUP_FAILED', error.message);
    } on FileSystemException catch (error) {
      return _refused(500, 'WRITE_FAILED', 'Config write failed: ${error.message}');
    }
  }

  ScheduleMutationResult? _reservedRefusal(String id, {required String noun, required String field}) =>
      reservedJobIds.contains(id)
      ? _refused(409, 'CONFLICT', '$noun "$id" is a built-in job and cannot be written through this API', field)
      : null;

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

  /// Writes [jobs] as the whole `scheduling.jobs` list, without loading them.
  ///
  /// Throws whatever [ConfigWriter.updateFields] throws — a `StateError` for a
  /// failed backup, a `FileSystemException` for a failed write — so a caller
  /// keeps its own mapping of those two failures. Use [commitAndApply] unless
  /// the running scheduler already holds the list being written.
  Future<void> commit(List<Map<String, dynamic>> jobs) => _synchronized(() => _commit(jobs));

  Future<void> _commit(List<Map<String, dynamic>> jobs) => _writer.updateFields({'scheduling.jobs': jobs});

  /// Writes [jobs] and loads them into the running scheduler before returning.
  ///
  /// The order is what makes a "created" answer true: the applier has replaced
  /// the scheduler's config-declared jobs by the time the caller responds.
  ///
  /// Throws [ShellJobWriteRefused] before any file change when [jobs] would add,
  /// remove or change a `type: shell` entry. The comparison is against a fresh
  /// read, not the caller's snapshot, because every mutation here is a
  /// read-modify-write over the whole list and a stale snapshot would let a
  /// concurrent hand edit through.
  ///
  /// [afterCommit] runs once the file is written and before the applier, for
  /// state that must agree with the file rather than with the load. When it
  /// fails, [recoverAfterCommitFailure] receives the pre-write job list and
  /// original error so approval can compensate through this same write path.
  /// An applier failure is surfaced separately from a config-write failure.
  Future<void> commitAndApply(
    List<Map<String, dynamic>> jobs, {
    Future<void> Function()? afterCommit,
    Future<void> Function(List<Map<String, dynamic>> previousJobs, Object error)? recoverAfterCommitFailure,
  }) => _synchronized(
    () => _commitAndApply(jobs, afterCommit: afterCommit, recoverAfterCommitFailure: recoverAfterCommitFailure),
  );

  Future<void> _commitAndApply(
    List<Map<String, dynamic>> jobs, {
    Future<void> Function()? afterCommit,
    Future<void> Function(List<Map<String, dynamic>> previousJobs, Object error)? recoverAfterCommitFailure,
  }) async {
    final previousJobs = await readJobs();
    final refusal = _shellWriteRefusal(previousJobs, jobs);
    if (refusal != null) throw ShellJobWriteRefused(refusal);
    await _commit(jobs);
    try {
      await afterCommit?.call();
    } catch (error, stackTrace) {
      if (recoverAfterCommitFailure != null) {
        await recoverAfterCommitFailure(previousJobs, error);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    try {
      await _applyJobs?.call();
    } catch (error) {
      throw _ScheduleJobsApplyFailed(error);
    }
  }

  /// Why [proposed] may not be written, or `null` when it leaves every
  /// `type: shell` entry exactly as [stored] has it.
  static String? _shellWriteRefusal(List<Map<String, dynamic>> stored, List<Map<String, dynamic>> proposed) {
    List<Map<String, dynamic>> shellEntries(List<Map<String, dynamic>> jobs) => [
      for (final job in jobs)
        if (job['type'] == 'shell') job,
    ];
    const equality = DeepCollectionEquality();
    final before = shellEntries(stored);
    final after = shellEntries(proposed);
    if (equality.equals(before, after)) return null;

    var changedIndex = 0;
    while (changedIndex < before.length &&
        changedIndex < after.length &&
        equality.equals(before[changedIndex], after[changedIndex])) {
      changedIndex++;
    }
    final changed = after.length < before.length ? before[changedIndex] : after[changedIndex];
    final id = (changed['id'] ?? changed['name']) as String? ?? '';
    return 'Shell jobs are file-only: edit scheduling.jobs in dartclaw.yaml ("$id")';
  }
}
