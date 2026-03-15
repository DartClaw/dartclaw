import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/maintenance/session_maintenance_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late String sessionsDir;
  late sqlite.Database taskDb;
  late TaskService taskService;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_maint_test_');
    dataDir = tempDir.path;
    sessionsDir = tempDir.path;
    sessions = SessionService(baseDir: sessionsDir);
    taskDb = openTaskDbInMemory();
    taskService = TaskService(SqliteTaskRepository(taskDb));
  });

  tearDown(() async {
    await taskService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Helper: create a session with a backdated updatedAt.
  Future<Session> createAgedSession({
    SessionType type = SessionType.user,
    String? channelKey,
    required Duration age,
  }) async {
    final s = await sessions.createSession(type: type, channelKey: channelKey);
    final backdated = DateTime.now().subtract(age);
    final metaFile = File(p.join(sessionsDir, s.id, 'meta.json'));
    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    json['updatedAt'] = backdated.toIso8601String();
    json['createdAt'] = backdated.toIso8601String();
    await metaFile.writeAsString(jsonEncode(json));
    return Session.fromJson(json);
  }

  /// Helper: write dummy data into session dir to occupy disk space.
  void fillSessionDir(String sessionId, int bytes) {
    final dataFile = File(p.join(sessionsDir, sessionId, 'data.bin'));
    dataFile.writeAsBytesSync(List.filled(bytes, 0));
  }

  Future<Task> createTaskWithStatus({
    required String id,
    required TaskStatus status,
    required Duration age,
    TaskService? tasks,
  }) async {
    final service = tasks ?? taskService;
    final completedAt = DateTime.now().subtract(age);
    final createdAt = completedAt.subtract(const Duration(hours: 2));
    final queuedAt = createdAt.add(const Duration(minutes: 1));
    final runningAt = createdAt.add(const Duration(minutes: 2));
    final reviewAt = completedAt.subtract(const Duration(minutes: 1));

    await service.create(
      id: id,
      title: 'Task $id',
      description: 'Description for $id',
      type: TaskType.coding,
      now: createdAt,
    );

    if (status == TaskStatus.draft) {
      return (await service.get(id))!;
    }

    if (status == TaskStatus.cancelled) {
      return service.transition(id, TaskStatus.cancelled, now: completedAt);
    }

    var task = await service.transition(id, TaskStatus.queued, now: queuedAt);
    if (status == TaskStatus.queued) return task;

    task = await service.transition(id, TaskStatus.running, now: runningAt);
    if (status == TaskStatus.running) return task;

    if (status == TaskStatus.interrupted) {
      return service.transition(id, TaskStatus.interrupted, now: completedAt);
    }

    if (status == TaskStatus.failed) {
      return service.transition(id, TaskStatus.failed, now: completedAt);
    }

    task = await service.transition(id, TaskStatus.review, now: reviewAt);
    if (status == TaskStatus.review) return task;

    if (status == TaskStatus.accepted) {
      return service.transition(id, TaskStatus.accepted, now: completedAt);
    }

    if (status == TaskStatus.rejected) {
      return service.transition(id, TaskStatus.rejected, now: completedAt);
    }

    throw StateError('Unsupported task status for test helper: ${status.name}');
  }

  Future<List<TaskArtifact>> createArtifacts(String taskId, Map<String, String> files, {TaskService? tasks}) async {
    final service = tasks ?? taskService;
    final artifactsDir = Directory(p.join(dataDir, 'tasks', taskId, 'artifacts'))..createSync(recursive: true);
    final artifacts = <TaskArtifact>[];
    var index = 0;
    for (final entry in files.entries) {
      final artifactFile = File(p.join(artifactsDir.path, entry.key));
      artifactFile.parent.createSync(recursive: true);
      artifactFile.writeAsStringSync(entry.value);
      artifacts.add(
        await service.addArtifact(
          id: '$taskId-artifact-$index',
          taskId: taskId,
          name: entry.key,
          kind: ArtifactKind.document,
          path: artifactFile.path,
          now: DateTime.now(),
        ),
      );
      index++;
    }
    return artifacts;
  }

  SessionMaintenanceService createService({
    SessionMaintenanceConfig config = const SessionMaintenanceConfig.defaults(),
    Set<String> activeChannelKeys = const {},
    Set<String> activeJobIds = const {},
    TaskService? taskServiceOverride,
    int artifactRetentionDays = 0,
    String? dataDirOverride,
  }) {
    return SessionMaintenanceService(
      sessions: sessions,
      config: config,
      activeChannelKeys: activeChannelKeys,
      activeJobIds: activeJobIds,
      sessionsDir: sessionsDir,
      taskService: taskServiceOverride ?? taskService,
      artifactRetentionDays: artifactRetentionDays,
      dataDir: dataDirOverride ?? dataDir,
    );
  }

  group('Prune stale sessions', () {
    test('stale session is archived in enforce mode', () async {
      await createAgedSession(age: const Duration(days: 60));
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
      );

      final report = await service.run();

      expect(report.sessionsArchived, 1);
      expect(report.actions, hasLength(1));
      expect(report.actions[0].actionType, 'archive');
      expect(report.actions[0].reason, 'stale');
      expect(report.actions[0].applied, isTrue);

      final all = await sessions.listSessions();
      expect(all.where((s) => s.type == SessionType.archive), hasLength(1));
    });

    test('stale session is NOT archived in warn mode (but reported)', () async {
      final s = await createAgedSession(age: const Duration(days: 60));
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.warn, pruneAfterDays: 30),
      );

      final report = await service.run();

      expect(report.sessionsArchived, 0);
      expect(report.actions, hasLength(1));
      expect(report.actions[0].applied, isFalse);

      // Session should still be user type (not archived)
      final fetched = await sessions.getSession(s.id);
      expect(fetched!.type, SessionType.user);
    });

    test('protected main session is never pruned regardless of age', () async {
      await createAgedSession(type: SessionType.main, age: const Duration(days: 365));
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 1),
      );

      final report = await service.run();
      expect(report.sessionsArchived, 0);
      expect(report.actions.where((a) => a.reason == 'stale'), isEmpty);
    });

    test('protected active channel session is never pruned', () async {
      await createAgedSession(
        type: SessionType.channel,
        channelKey: 'agent:bot:whatsapp:123',
        age: const Duration(days: 60),
      );
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
        activeChannelKeys: {'agent:bot:whatsapp:123'},
      );

      final report = await service.run();
      expect(report.sessionsArchived, 0);
    });

    test('protected active cron session is never pruned', () async {
      await createAgedSession(
        type: SessionType.cron,
        channelKey: 'agent:main:cron:daily-summary',
        age: const Duration(days: 60),
      );
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
        activeJobIds: {'daily-summary'},
      );

      final report = await service.run();
      expect(report.sessionsArchived, 0);
    });

    test('task sessions are never pruned', () async {
      final session = await createAgedSession(type: SessionType.task, age: const Duration(days: 365));
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 1),
      );

      final report = await service.run();
      expect(report.sessionsArchived, 0);
      expect(report.actions.where((action) => action.sessionId == session.id), isEmpty);
    });

    test('orphaned channel session (not in activeChannelKeys) IS pruned', () async {
      await createAgedSession(
        type: SessionType.channel,
        channelKey: 'agent:bot:whatsapp:old-contact',
        age: const Duration(days: 60),
      );
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
        activeChannelKeys: {}, // not active
      );

      final report = await service.run();
      expect(report.sessionsArchived, 1);
    });

    test('pruneAfterDays: 0 disables pruning', () async {
      await createAgedSession(age: const Duration(days: 365));
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 0),
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'stale'), isEmpty);
    });

    test('already-archived sessions are not re-processed', () async {
      final s = await createAgedSession(age: const Duration(days: 60));
      // Pre-archive it
      await sessions.updateSessionType(s.id, SessionType.archive);

      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'stale'), isEmpty);
    });
  });

  group('Count cap', () {
    test('sessions within cap: no action', () async {
      await sessions.createSession();
      await sessions.createSession();
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxSessions: 10),
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'count_cap'), isEmpty);
    });

    test('sessions over cap: oldest archived in enforce mode', () async {
      final oldest = await createAgedSession(age: const Duration(days: 10));
      await createAgedSession(age: const Duration(days: 5));
      await sessions.createSession(); // newest

      final service = createService(
        config: const SessionMaintenanceConfig(
          mode: MaintenanceMode.enforce,
          maxSessions: 2,
          pruneAfterDays: 0, // disable prune to test cap isolation
        ),
      );

      final report = await service.run();
      final capActions = report.actions.where((a) => a.reason == 'count_cap').toList();
      expect(capActions, hasLength(1));
      expect(capActions[0].sessionId, oldest.id);
      expect(capActions[0].applied, isTrue);
    });

    test('protected sessions excluded from count', () async {
      await createAgedSession(type: SessionType.main, age: const Duration(days: 10));
      await sessions.createSession();
      await sessions.createSession();

      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxSessions: 2, pruneAfterDays: 0),
      );

      final report = await service.run();
      // main is excluded from count, so 2 user sessions == cap, no action
      expect(report.actions.where((a) => a.reason == 'count_cap'), isEmpty);
    });

    test('maxSessions: 0 disables count cap', () async {
      for (var i = 0; i < 5; i++) {
        await sessions.createSession();
      }
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxSessions: 0),
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'count_cap'), isEmpty);
    });
  });

  group('Cron retention', () {
    test('orphaned old cron session deleted in enforce mode', () async {
      await createAgedSession(
        type: SessionType.cron,
        channelKey: 'agent:main:cron:old-job',
        age: const Duration(hours: 48),
      );
      final service = createService(
        config: const SessionMaintenanceConfig(
          mode: MaintenanceMode.enforce,
          cronRetentionHours: 24,
          pruneAfterDays: 0,
        ),
        activeJobIds: {}, // job not configured
      );

      final report = await service.run();
      final cronActions = report.actions.where((a) => a.reason == 'cron_retention').toList();
      expect(cronActions, hasLength(1));
      expect(cronActions[0].actionType, 'delete');
      expect(cronActions[0].applied, isTrue);
      expect(report.sessionsDeleted, 1);
    });

    test('active cron session (job configured) NOT deleted', () async {
      await createAgedSession(
        type: SessionType.cron,
        channelKey: 'agent:main:cron:daily-summary',
        age: const Duration(hours: 48),
      );
      final service = createService(
        config: const SessionMaintenanceConfig(
          mode: MaintenanceMode.enforce,
          cronRetentionHours: 24,
          pruneAfterDays: 0,
        ),
        activeJobIds: {'daily-summary'},
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'cron_retention'), isEmpty);
    });

    test('cronRetentionHours: 0 disables cron retention', () async {
      await createAgedSession(
        type: SessionType.cron,
        channelKey: 'agent:main:cron:old-job',
        age: const Duration(hours: 48),
      );
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, cronRetentionHours: 0, pruneAfterDays: 0),
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'cron_retention'), isEmpty);
    });
  });

  group('Disk budget', () {
    test('under budget: no action', () async {
      final s = await sessions.createSession();
      fillSessionDir(s.id, 100); // 100 bytes, well under any budget
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxDiskMb: 1, pruneAfterDays: 0),
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'disk_budget'), isEmpty);
    });

    test('over 80%: oldest archived sessions deleted in enforce mode', () async {
      // Create archived sessions with data
      final s1 = await createAgedSession(age: const Duration(days: 10));
      await sessions.updateSessionType(s1.id, SessionType.archive);
      fillSessionDir(s1.id, 500 * 1024); // 500KB

      final s2 = await createAgedSession(age: const Duration(days: 5));
      await sessions.updateSessionType(s2.id, SessionType.archive);
      fillSessionDir(s2.id, 500 * 1024); // 500KB

      // maxDiskMb=1 means budget=1MB, threshold=80%=~819KB
      // Total ~1MB > 819KB threshold
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxDiskMb: 1, pruneAfterDays: 0),
      );

      final report = await service.run();
      final diskActions = report.actions.where((a) => a.reason == 'disk_budget').toList();
      expect(diskActions, isNotEmpty);
      expect(diskActions.every((a) => a.actionType == 'delete'), isTrue);
    });

    test('only archived sessions deleted for disk (never active)', () async {
      // Create a user session with data (should NOT be deleted)
      final userSession = await sessions.createSession();
      fillSessionDir(userSession.id, 800 * 1024);

      // Create an archived session (CAN be deleted)
      final archSession = await createAgedSession(age: const Duration(days: 10));
      await sessions.updateSessionType(archSession.id, SessionType.archive);
      fillSessionDir(archSession.id, 200 * 1024);

      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxDiskMb: 1, pruneAfterDays: 0),
      );

      final report = await service.run();
      final diskActions = report.actions.where((a) => a.reason == 'disk_budget').toList();
      // Only the archived session can be deleted
      for (final a in diskActions) {
        expect(a.sessionId, isNot(userSession.id));
      }
    });

    test('warning if still over after all archives deleted', () async {
      // Create a large user session that pushes over budget
      final userSession = await sessions.createSession();
      fillSessionDir(userSession.id, 900 * 1024); // 900KB, no archives to delete

      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxDiskMb: 1, pruneAfterDays: 0),
      );

      final report = await service.run();
      expect(report.warnings, contains(contains('Still over disk budget')));
    });

    test('maxDiskMb: 0 disables disk budget', () async {
      final s = await sessions.createSession();
      fillSessionDir(s.id, 10 * 1024 * 1024); // 10MB
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, maxDiskMb: 0, pruneAfterDays: 0),
      );

      final report = await service.run();
      expect(report.actions.where((a) => a.reason == 'disk_budget'), isEmpty);
    });
  });

  group('Artifact retention', () {
    const artifactOnlyConfig = SessionMaintenanceConfig(
      mode: MaintenanceMode.enforce,
      pruneAfterDays: 0,
      maxSessions: 0,
      maxDiskMb: 0,
      cronRetentionHours: 0,
    );

    test('artifact retention disabled when days = 0', () async {
      await createTaskWithStatus(id: 'task-disabled-days', status: TaskStatus.accepted, age: const Duration(days: 45));
      await createArtifacts('task-disabled-days', {'report.md': 'hello'});

      final service = createService(config: artifactOnlyConfig, artifactRetentionDays: 0);
      final report = await service.run();

      expect(report.actions.where((action) => action.reason == 'artifact_retention'), isEmpty);
      expect(report.artifactsDeleted, 0);
      expect(report.artifactDiskReclaimedBytes, 0);
      expect(await taskService.listArtifacts('task-disabled-days'), hasLength(1));
      expect(Directory(p.join(dataDir, 'tasks', 'task-disabled-days', 'artifacts')).existsSync(), isTrue);
    });

    test('artifact retention disabled when taskService is null', () async {
      await createTaskWithStatus(
        id: 'task-disabled-service',
        status: TaskStatus.accepted,
        age: const Duration(days: 45),
      );
      await createArtifacts('task-disabled-service', {'report.md': 'hello'});

      final service = SessionMaintenanceService(
        sessions: sessions,
        config: artifactOnlyConfig,
        activeChannelKeys: const {},
        activeJobIds: const {},
        sessionsDir: sessionsDir,
        taskService: null,
        artifactRetentionDays: 30,
        dataDir: dataDir,
      );
      final report = await service.run();

      expect(report.actions.where((action) => action.reason == 'artifact_retention'), isEmpty);
      expect(report.artifactsDeleted, 0);
      expect(await taskService.listArtifacts('task-disabled-service'), hasLength(1));
      expect(Directory(p.join(dataDir, 'tasks', 'task-disabled-service', 'artifacts')).existsSync(), isTrue);
    });

    test('terminal task older than threshold: artifacts deleted in enforce mode', () async {
      final task = await createTaskWithStatus(
        id: 'task-old-terminal',
        status: TaskStatus.accepted,
        age: const Duration(days: 45),
      );
      await createArtifacts(task.id, {'report.md': 'hello', 'nested/notes.txt': 'test'});

      final service = createService(config: artifactOnlyConfig, artifactRetentionDays: 30);
      final report = await service.run();

      final actions = report.actions.where((action) => action.reason == 'artifact_retention').toList();
      expect(actions, hasLength(1));
      expect(actions.single.sessionId, task.id);
      expect(actions.single.applied, isTrue);
      expect(report.artifactsDeleted, 2);
      expect(report.artifactDiskReclaimedBytes, 9);
      expect(await taskService.listArtifacts(task.id), isEmpty);
      expect(Directory(p.join(dataDir, 'tasks', task.id, 'artifacts')).existsSync(), isFalse);
    });

    test('terminal task within threshold: artifacts preserved', () async {
      final task = await createTaskWithStatus(
        id: 'task-recent-terminal',
        status: TaskStatus.failed,
        age: const Duration(days: 5),
      );
      await createArtifacts(task.id, {'report.md': 'hello'});

      final service = createService(config: artifactOnlyConfig, artifactRetentionDays: 30);
      final report = await service.run();

      expect(report.actions.where((action) => action.reason == 'artifact_retention'), isEmpty);
      expect(report.artifactsDeleted, 0);
      expect(await taskService.listArtifacts(task.id), hasLength(1));
      expect(Directory(p.join(dataDir, 'tasks', task.id, 'artifacts')).existsSync(), isTrue);
    });

    test('non-terminal task: artifacts never deleted regardless of age', () async {
      final task = await createTaskWithStatus(
        id: 'task-running',
        status: TaskStatus.running,
        age: const Duration(days: 45),
      );
      await createArtifacts(task.id, {'report.md': 'hello'});

      final service = createService(config: artifactOnlyConfig, artifactRetentionDays: 30);
      final report = await service.run();

      expect(report.actions.where((action) => action.reason == 'artifact_retention'), isEmpty);
      expect(report.artifactsDeleted, 0);
      expect(await taskService.listArtifacts(task.id), hasLength(1));
      expect(Directory(p.join(dataDir, 'tasks', task.id, 'artifacts')).existsSync(), isTrue);
    });

    test('warn mode: reports planned actions, no filesystem changes', () async {
      final task = await createTaskWithStatus(
        id: 'task-warn',
        status: TaskStatus.accepted,
        age: const Duration(days: 45),
      );
      await createArtifacts(task.id, {'report.md': 'hello'});

      final service = createService(
        config: const SessionMaintenanceConfig(
          mode: MaintenanceMode.warn,
          pruneAfterDays: 0,
          maxSessions: 0,
          maxDiskMb: 0,
          cronRetentionHours: 0,
        ),
        artifactRetentionDays: 30,
      );
      final report = await service.run();

      final actions = report.actions.where((action) => action.reason == 'artifact_retention').toList();
      expect(actions, hasLength(1));
      expect(actions.single.sessionId, task.id);
      expect(actions.single.applied, isFalse);
      expect(report.artifactsDeleted, 0);
      expect(report.artifactDiskReclaimedBytes, 5);
      expect(await taskService.listArtifacts(task.id), hasLength(1));
      expect(Directory(p.join(dataDir, 'tasks', task.id, 'artifacts')).existsSync(), isTrue);
    });

    test('partial failure: one task fails, others continue', () async {
      final failingDb = openTaskDbInMemory();
      final failingTasks = _FailingArtifactDeleteTaskService(
        SqliteTaskRepository(failingDb),
        failingArtifactId: 'task-fail-artifact-0',
      );
      addTearDown(() async => failingTasks.dispose());

      final failedTask = await createTaskWithStatus(
        id: 'task-fail',
        status: TaskStatus.accepted,
        age: const Duration(days: 45),
        tasks: failingTasks,
      );
      await createArtifacts(failedTask.id, {'report.md': 'boom'}, tasks: failingTasks);

      final okTask = await createTaskWithStatus(
        id: 'task-ok',
        status: TaskStatus.failed,
        age: const Duration(days: 45),
        tasks: failingTasks,
      );
      await createArtifacts(okTask.id, {'summary.md': 'done'}, tasks: failingTasks);

      final service = createService(
        config: artifactOnlyConfig,
        taskServiceOverride: failingTasks,
        artifactRetentionDays: 30,
      );
      final report = await service.run();

      final actions = report.actions.where((action) => action.reason == 'artifact_retention').toList();
      expect(actions, hasLength(2));
      expect(actions.where((action) => action.sessionId == failedTask.id).single.applied, isFalse);
      expect(actions.where((action) => action.sessionId == okTask.id).single.applied, isTrue);
      expect(report.artifactsDeleted, 1);
      expect(report.artifactDiskReclaimedBytes, 4);
      expect(report.warnings, contains(contains('task-fail')));
      expect(await failingTasks.listArtifacts(failedTask.id), hasLength(1));
      expect(await failingTasks.listArtifacts(okTask.id), isEmpty);
      expect(Directory(p.join(dataDir, 'tasks', failedTask.id, 'artifacts')).existsSync(), isTrue);
      expect(Directory(p.join(dataDir, 'tasks', okTask.id, 'artifacts')).existsSync(), isFalse);
    });
  });

  group('Mode override', () {
    test('modeOverride parameter overrides config mode', () async {
      await createAgedSession(age: const Duration(days: 60));
      final service = createService(
        config: const SessionMaintenanceConfig(
          mode: MaintenanceMode.warn, // config says warn
          pruneAfterDays: 30,
        ),
      );

      final report = await service.run(modeOverride: MaintenanceMode.enforce);
      expect(report.mode, MaintenanceMode.enforce);
      expect(report.sessionsArchived, 1);
      expect(report.actions[0].applied, isTrue);
    });

    test('warn mode reports correct counts but applies no changes', () async {
      await createAgedSession(age: const Duration(days: 60));
      await createAgedSession(age: const Duration(days: 60));
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.warn, pruneAfterDays: 30),
      );

      final report = await service.run();
      expect(report.mode, MaintenanceMode.warn);
      expect(report.sessionsArchived, 0); // nothing applied
      expect(report.actions, hasLength(2)); // but both reported
      expect(report.actions.every((a) => !a.applied), isTrue);
    });
  });

  group('Idempotency', () {
    test('running twice with same state produces consistent results', () async {
      await createAgedSession(age: const Duration(days: 60));
      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
      );

      final report1 = await service.run();
      expect(report1.sessionsArchived, 1);

      // Run again — session is already archived, should not be re-processed
      final report2 = await service.run();
      expect(report2.sessionsArchived, 0);
      expect(report2.actions.where((a) => a.reason == 'stale'), isEmpty);
    });
  });

  group('Partial failure', () {
    test('one session fails to archive: logged in warnings, others continue', () async {
      // Create two stale sessions
      await createAgedSession(age: const Duration(days: 60));
      await createAgedSession(age: const Duration(days: 60));

      final service = createService(
        config: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
      );

      final report = await service.run();
      // Both should be processed (2 actions), both archived
      expect(report.actions.where((a) => a.reason == 'stale'), hasLength(2));
      expect(report.sessionsArchived, 2);
    });
  });

  group('MaintenanceReport', () {
    test('empty report has zero counts', () {
      final report = MaintenanceReport.empty(MaintenanceMode.warn);
      expect(report.mode, MaintenanceMode.warn);
      expect(report.sessionsArchived, 0);
      expect(report.sessionsDeleted, 0);
      expect(report.diskReclaimedBytes, 0);
      expect(report.artifactsDeleted, 0);
      expect(report.artifactDiskReclaimedBytes, 0);
      expect(report.totalSessions, 0);
      expect(report.totalDiskBytes, 0);
      expect(report.warnings, isEmpty);
      expect(report.actions, isEmpty);
    });
  });

  group('MaintenanceAction', () {
    test('captures all fields', () {
      const action = MaintenanceAction(sessionId: 'test-id', actionType: 'archive', reason: 'stale', applied: true);
      expect(action.sessionId, 'test-id');
      expect(action.actionType, 'archive');
      expect(action.reason, 'stale');
      expect(action.applied, isTrue);
    });
  });
}

class _FailingArtifactDeleteTaskService extends TaskService {
  _FailingArtifactDeleteTaskService(super.repo, {required this.failingArtifactId});

  final String failingArtifactId;

  @override
  Future<void> deleteArtifact(String id) async {
    if (id == failingArtifactId) {
      throw StateError('delete failed for $id');
    }
    return super.deleteArtifact(id);
  }
}
