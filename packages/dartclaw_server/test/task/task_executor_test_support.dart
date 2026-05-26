// Shared setUp/tearDown harness for TaskExecutor-level tests.
//
// Used by task_executor_test.dart, retry_enforcement_test.dart, and
// budget_enforcement_test.dart to share the standard topology:
//   tempDir → sessions, messages, tasks, turns, collector → tearDown.
//
// Tests that need additional fields (kvService, workflow repos, goals) declare
// those locally on top of the shared base. Tests that need a different TaskService
// (e.g. one backed by a shared DB with workflow repos) may replace [tasks] and
// [collector] after calling [setUp]; pass [tasksDispose] to [tearDown] in that
// case so the harness doesn't double-dispose the default instance.
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Shared topology harness for [TaskExecutor] tests.
///
/// Call [setUp] in the test group setUp hook and [tearDown] in tearDown.
/// Access [tempDir], [sessionsDir], [workspaceDir], [sessions], [messages],
/// [tasks], [turns], [collector] directly from tests.
///
/// Tests that need a workflow-aware [TaskService] may replace [tasks] and
/// [collector] after [setUp] returns, then pass a [tasksDispose] callback to
/// [tearDown] so the harness skips disposing the default instance.
final class TaskExecutorTestHarness {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late TurnManager turns;
  late ArtifactCollector collector;

  /// Default [TaskService] created by [setUp], used for disposal tracking.
  late TaskService _defaultTasks;

  final AgentHarness worker;

  TaskExecutorTestHarness(this.worker);

  Future<void> setUp({String tempPrefix = 'dartclaw_executor_test_'}) async {
    tempDir = Directory.systemTemp.createTempSync(tempPrefix);
    sessionsDir = p.join(tempDir.path, 'sessions');
    // Workspace must NOT be inside dataDir — ArtifactCollector excludes
    // files within dataDir to prevent collecting internal metadata.
    workspaceDir = Directory.systemTemp.createTempSync('${tempPrefix}ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    _defaultTasks = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    tasks = _defaultTasks;
    turns = TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
    collector = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
    );
  }

  Future<void> tearDown({
    TaskExecutor? executor,
    Future<void> Function()? workerDispose,
    Future<void> Function()? tasksDispose,
  }) async {
    if (executor != null) await executor.stop();
    if (tasksDispose != null) {
      // Test replaced the default TaskService — dispose both.
      if (!identical(tasks, _defaultTasks)) await _defaultTasks.dispose();
      await tasksDispose();
    } else {
      await _defaultTasks.dispose();
    }
    await messages.dispose();
    if (workerDispose != null) await workerDispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  }
}
