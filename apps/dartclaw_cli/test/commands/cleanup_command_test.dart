import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/cleanup_command.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository, openTaskDb;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late List<String> output;
  late int? exitCode;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_cleanup_test_');
    sessionsDir = '${tempDir.path}/sessions';
    Directory(sessionsDir).createSync(recursive: true);
    output = [];
    exitCode = null;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Runs the cleanup command via a CommandRunner with the given [args].
  Future<void> runCleanup(List<String> args, {DartclawConfig? config}) async {
    final cfg = config ?? DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final command = CleanupCommand(config: cfg, writeLine: output.add, exitFn: (code) => exitCode = code);

    final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(_TestSessionsCommand(command));

    await runner.run(['sessions', 'cleanup', ...args]);
  }

  group('CleanupCommand', () {
    test('name is cleanup', () {
      final cmd = CleanupCommand();
      expect(cmd.name, 'cleanup');
    });

    test('description is set', () {
      final cmd = CleanupCommand();
      expect(cmd.description, isNotEmpty);
    });

    test('cleanup with empty sessions dir reports no actions', () async {
      await runCleanup([]);

      expect(output, anyElement(contains('Session Maintenance Report')));
      expect(output, anyElement(contains('No actions needed.')));
      expect(exitCode, 0);
    });

    test('cleanup with --dry-run always uses warn mode', () async {
      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce)),
      );

      await runCleanup(['--dry-run'], config: config);

      expect(output, anyElement(contains('warn (--dry-run override)')));
      expect(exitCode, 0);
    });

    test('cleanup with --enforce always uses enforce mode', () async {
      await runCleanup(['--enforce']);

      expect(output, anyElement(contains('enforce (--enforce override)')));
      expect(exitCode, 0);
    });

    test('cleanup with no flags respects config mode', () async {
      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce)),
      );

      await runCleanup([], config: config);

      expect(output, anyElement(contains('enforce (config)')));
      expect(exitCode, 0);
    });

    test('cleanup with both --dry-run and --enforce throws UsageException', () async {
      expect(() => runCleanup(['--dry-run', '--enforce']), throwsA(isA<UsageException>()));
    });

    test('output format includes summary sections', () async {
      await runCleanup([]);

      expect(output, anyElement(contains('Session Maintenance Report')));
      expect(output, anyElement(contains('Mode:')));
      expect(output, anyElement(contains('Sessions:')));
      expect(output, anyElement(contains('Disk usage:')));
    });

    test('cleanup exit code 0 on success', () async {
      await runCleanup([]);
      expect(exitCode, 0);
    });

    test('cleanup archives stale sessions in enforce mode', () async {
      // Create a stale session
      final sessions = SessionService(baseDir: sessionsDir);
      final s = await sessions.createSession();
      _backdateSession(sessionsDir, s.id, const Duration(days: 60));

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(
          maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
        ),
      );

      await runCleanup([], config: config);

      expect(output, anyElement(contains('Archived:')));
      expect(output, anyElement(contains('stale')));
      expect(exitCode, 0);
    });

    test('cleanup with --dry-run does not modify sessions', () async {
      final sessions = SessionService(baseDir: sessionsDir);
      final s = await sessions.createSession();
      _backdateSession(sessionsDir, s.id, const Duration(days: 60));

      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        sessions: SessionConfig(
          maintenanceConfig: const SessionMaintenanceConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 30),
        ),
      );

      await runCleanup(['--dry-run'], config: config);

      // Session should still be user type (not archived)
      final fetched = await sessions.getSession(s.id);
      expect(fetched!.type, SessionType.user);
    });
  });

  group('CleanupCommand workflow runtime-artifacts retention', () {
    DartclawConfig configWith(WorkflowRuntimeArtifactsRetentionConfig retention) => DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      workflow: WorkflowConfig(runtimeArtifactsRetention: retention),
    );

    Directory seedRunArtifacts(String runId) {
      final runDir = Directory(p.join(tempDir.path, 'workflows', 'runs', runId))..createSync(recursive: true);
      File(p.join(runDir.path, 'context.json')).writeAsStringSync('{}');
      final artifactsDir = Directory(p.join(runDir.path, 'runtime-artifacts', 'reviews'))..createSync(recursive: true);
      File(p.join(artifactsDir.path, 'report.md')).writeAsStringSync('# review\n');
      return Directory(p.join(runDir.path, 'runtime-artifacts'));
    }

    Future<void> seedCompletedRun(DartclawConfig config, String runId, {required Duration age}) async {
      final db = openTaskDb(config.tasksDbPath);
      try {
        final repo = SqliteWorkflowRunRepository(db);
        final completedAt = DateTime.now().subtract(age);
        await repo.insert(
          WorkflowRun(
            id: runId,
            definitionName: 'spec-and-implement',
            status: WorkflowRunStatus.completed,
            startedAt: completedAt.subtract(const Duration(hours: 1)),
            updatedAt: completedAt,
            completedAt: completedAt,
          ),
        );
      } finally {
        db.close();
      }
    }

    test('enforce prunes an old completed run runtime-artifacts and keeps context.json', () async {
      final config = configWith(
        const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      );
      final artifacts = seedRunArtifacts('run-old');
      await seedCompletedRun(config, 'run-old', age: const Duration(days: 10));

      await runCleanup([], config: config);

      expect(artifacts.existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'workflows', 'runs', 'run-old', 'context.json')).existsSync(), isTrue);
      expect(output, anyElement(contains('Workflow Runtime-Artifacts Retention')));
      expect(output, anyElement(contains('run-old')));
      expect(exitCode, 0);
    });

    test('--dry-run lists the candidate run without removing it', () async {
      final config = configWith(
        const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      );
      final artifacts = seedRunArtifacts('run-old');
      await seedCompletedRun(config, 'run-old', age: const Duration(days: 10));

      await runCleanup(['--dry-run'], config: config);

      expect(artifacts.existsSync(), isTrue);
      expect(output, anyElement(contains('Would prune')));
      expect(output, anyElement(contains('run-old')));
    });

    test('disabled retention (prune_after_days 0) is a no-op and prints no retention section', () async {
      final config = configWith(const WorkflowRuntimeArtifactsRetentionConfig());
      final artifacts = seedRunArtifacts('run-old');
      await seedCompletedRun(config, 'run-old', age: const Duration(days: 10));

      await runCleanup([], config: config);

      expect(artifacts.existsSync(), isTrue);
      expect(output, isNot(anyElement(contains('Workflow Runtime-Artifacts Retention'))));
    });

    test('a corrupt tasks.db degrades to a skip warning and exit 1 instead of crashing', () async {
      final config = configWith(
        const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      );
      // Write a non-SQLite garbage file at the tasks DB path so the repository's
      // schema-init DDL throws from its constructor.
      File(config.tasksDbPath).writeAsStringSync('not a sqlite database at all');

      // Must not throw — the command degrades to a warning + exit 1.
      await runCleanup([], config: config);

      expect(output, anyElement(contains('workflow artifact retention skipped')));
      expect(exitCode, 1);
    });

    test('enforce reports only successful deletions when one run dir is non-deletable', () async {
      if (Platform.isWindows) {
        markTestSkipped('POSIX permission model only');
        return;
      }
      final config = configWith(
        const WorkflowRuntimeArtifactsRetentionConfig(mode: MaintenanceMode.enforce, pruneAfterDays: 7),
      );
      final deletable = seedRunArtifacts('run-deletable');
      seedRunArtifacts('run-locked');
      await seedCompletedRun(config, 'run-deletable', age: const Duration(days: 10));
      await seedCompletedRun(config, 'run-locked', age: const Duration(days: 10));

      // Make run-locked's run dir read-only so deleting its runtime-artifacts
      // subtree fails (POSIX requires write+execute on the parent to remove a child).
      final lockedRunDir = Directory(p.join(tempDir.path, 'workflows', 'runs', 'run-locked'));
      Process.runSync('chmod', ['500', lockedRunDir.path]);
      addTearDown(() => Process.runSync('chmod', ['700', lockedRunDir.path]));

      await runCleanup([], config: config);

      expect(deletable.existsSync(), isFalse);
      expect(output, anyElement(contains('Pruned:           1 run')));
      expect(output, anyElement(contains('run-deletable')));
      expect(output, isNot(anyElement(contains('  - run-locked'))));
      expect(output, anyElement(contains('Warnings:')));
      expect(output, anyElement(contains('run-locked')));
      expect(exitCode, 1);
    });
  });
}

/// Test wrapper for SessionsCommand that uses a pre-configured CleanupCommand.
class _TestSessionsCommand extends Command<void> {
  _TestSessionsCommand(CleanupCommand cleanup) {
    addSubcommand(cleanup);
  }

  @override
  String get name => 'sessions';

  @override
  String get description => 'test sessions';
}

void _backdateSession(String sessionsDir, String sessionId, Duration age) {
  final metaFile = File('$sessionsDir/$sessionId/meta.json');
  final content = metaFile.readAsStringSync();
  final backdated = DateTime.now().subtract(age).toIso8601String();
  // Replace the updatedAt timestamp
  final updated = content.replaceAllMapped(RegExp(r'"updatedAt":"[^"]*"'), (m) => '"updatedAt":"$backdated"');
  metaFile.writeAsStringSync(updated);
}
