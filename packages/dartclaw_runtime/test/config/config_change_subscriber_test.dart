import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:test/test.dart';

/// `PATCH /api/config` is the only transport that delivers exact dotted keys
/// here — `ConfigNotifier` emits section wildcards to `Reconfigurable`s — so
/// these are the assertions that keep the `live` tier honest for the two
/// built-in jobs the heartbeat/git-sync fold produced.
void main() {
  late Directory workspace;
  late EventBus eventBus;
  late RuntimeConfig runtimeConfig;
  late ScheduleService schedule;
  late WorkspaceGitSync gitSync;
  late ConfigChangeSubscriber subscriber;

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('config_change_subscriber_');
    eventBus = EventBus();
    runtimeConfig = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: true);
    gitSync = WorkspaceGitSync(workspaceDir: workspace.path, commandRunner: RecordingGitRunner().run);
    await gitSync.isGitAvailable();
    schedule = ScheduleService(
      turns: FakeTurnManager(),
      sessions: SessionService(baseDir: '${workspace.path}/sessions'),
      jobs: [
        buildHeartbeatJob(workspaceDir: workspace.path, intervalMinutes: 30),
        buildWorkspaceGitSyncJob(gitSync, intervalMinutes: 30).job,
      ],
    )..start();
    subscriber = ConfigChangeSubscriber(runtimeConfig: runtimeConfig, scheduleService: schedule, gitSync: gitSync)
      ..subscribe(eventBus);
  });

  tearDown(() async {
    await subscriber.cancel();
    schedule.stop();
    await eventBus.dispose();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  Future<void> fire(String key, Object value) async {
    eventBus.fire(
      ConfigChangedEvent(
        changedKeys: [key],
        oldValues: const {},
        newValues: {key: value},
        requiresRestart: false,
        timestamp: DateTime.now(),
      ),
    );
    await pumpEventQueue();
  }

  for (final entry in <({String key, String jobId})>[
    (key: 'scheduling.heartbeat.enabled', jobId: heartbeatJobId),
    (key: 'workspace.git_sync.enabled', jobId: workspaceGitSyncJobId),
  ]) {
    test('${entry.key} pauses and resumes the built-in job in both directions', () async {
      await fire(entry.key, false);
      expect(schedule.isJobPaused(entry.jobId), isTrue);

      await fire(entry.key, true);
      expect(schedule.isJobPaused(entry.jobId), isFalse);

      // Idempotent: a repeat of the current value must not flip the job.
      await fire(entry.key, true);
      expect(schedule.isJobPaused(entry.jobId), isFalse);
    });
  }

  test('the enabled keys also move the displayed runtime flags', () async {
    await fire('scheduling.heartbeat.enabled', false);
    await fire('workspace.git_sync.enabled', false);

    expect(runtimeConfig.heartbeatEnabled, isFalse);
    expect(runtimeConfig.gitSyncEnabled, isFalse);
  });

  test('workspace.git_sync.push_enabled still applies straight to WorkspaceGitSync', () async {
    await fire('workspace.git_sync.push_enabled', false);

    expect(gitSync.pushEnabled, isFalse);
    expect(runtimeConfig.gitSyncPushEnabled, isFalse);
    expect(schedule.isJobPaused(workspaceGitSyncJobId), isFalse, reason: 'push is not the sync on/off switch');
  });
}
