import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late List<String> invocations;
  late WorkspaceGitSync sync;
  late String statusOutput;
  late bool hasRemote;

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('git_sync_job_');
    invocations = [];
    statusOutput = ' M MEMORY.md\n';
    hasRemote = false;
    sync = WorkspaceGitSync(
      workspaceDir: workspace.path,
      commandRunner: RecordingGitRunner(
        responder: (call) {
          invocations.add(['git', ...call.arguments].join(' '));
          if (call.arguments.first == 'status') return ProcessResult(0, 0, statusOutput, '');
          if (call.arguments.first == 'remote') {
            return hasRemote
                ? ProcessResult(0, 0, 'git@example.com:ws.git\n', '')
                : ProcessResult(0, 1, '', 'no remote');
          }
          return null;
        },
      ).run,
    );
    await sync.isGitAvailable();
    invocations.clear();
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('the built-in job carries the git-sync id and its configured interval', () {
    final built = buildWorkspaceGitSyncJob(sync, intervalMinutes: 5);

    expect(built.job.id, workspaceGitSyncJobId);
    expect(built.job.scheduleType, ScheduleType.interval);
    expect(built.job.intervalMinutes, 5);
    expect(built.displayJob['name'], workspaceGitSyncJobId);
    expect(built.displayJob['schedule'], 'every 5 minutes');
    expect(built.displayJob['status'], 'active');
    expect(buildWorkspaceGitSyncJob(sync, intervalMinutes: 5, enabled: false).displayJob['status'], 'paused');
  });

  test('an uncommitted change is committed when the interval elapses with the heartbeat disabled', () async {
    final gitSyncJob = buildWorkspaceGitSyncJob(sync, intervalMinutes: 30).job;
    final heartbeat = buildHeartbeatJob(workspaceDir: workspace.path, intervalMinutes: 30);
    final service = ScheduleService(
      turns: FakeTurnManager(),
      sessions: _NoopSessionService(),
      jobs: [heartbeat, gitSyncJob],
    )..start();
    addTearDown(service.stop);
    // The operator turned the heartbeat off; git sync must keep its own cadence.
    service.pauseJob(heartbeatJobId);

    await service.executeJobForTesting(gitSyncJob);

    expect(invocations, contains('git add .'));
    expect(invocations.any((invocation) => invocation.startsWith('git commit -m')), isTrue);
  });

  test('a configured remote is pushed when push_enabled is set, and skipped when it is not', () async {
    hasRemote = true;
    final gitSyncJob = buildWorkspaceGitSyncJob(sync, intervalMinutes: 30).job;
    final service = ScheduleService(turns: FakeTurnManager(), sessions: _NoopSessionService(), jobs: [gitSyncJob])
      ..start();
    addTearDown(service.stop);

    await service.executeJobForTesting(gitSyncJob);
    expect(invocations, contains('git push'));

    invocations.clear();
    sync.pushEnabled = false;
    await service.executeJobForTesting(gitSyncJob);
    expect(invocations, isNot(contains('git push')));
  });

  test('a clean workspace stages and commits nothing', () async {
    statusOutput = '';
    final gitSyncJob = buildWorkspaceGitSyncJob(sync, intervalMinutes: 30).job;
    final service = ScheduleService(turns: FakeTurnManager(), sessions: _NoopSessionService(), jobs: [gitSyncJob])
      ..start();
    addTearDown(service.stop);

    await service.executeJobForTesting(gitSyncJob);

    expect(invocations, contains('git status --porcelain'));
    expect(invocations, isNot(contains('git add .')));
  });
}

class _NoopSessionService implements SessionService {
  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async => Session(id: 'session-$key', type: type, createdAt: DateTime.now(), updatedAt: DateTime.now());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
