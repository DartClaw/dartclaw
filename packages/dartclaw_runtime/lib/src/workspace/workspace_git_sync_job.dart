import '../scheduling/scheduled_job.dart';
import 'workspace_git_sync.dart';

/// Reserved id of the built-in workspace git-sync job.
///
/// The live `workspace.git_sync.enabled` toggle pauses and resumes this job,
/// so the id is part of the runtime control surface, not a label.
const workspaceGitSyncJobId = 'git-sync';

/// Builds the built-in workspace git-sync job and its scheduling-UI row.
///
/// Git sync owns this schedule outright: it no longer rides the heartbeat, so
/// an operator who disables the heartbeat keeps versioned workspace memory.
///
/// [enabled] is the boot value of `workspace.git_sync.enabled`: the job is
/// registered either way, and the row reports the pause state it starts in.
({ScheduledJob job, Map<String, dynamic> displayJob}) buildWorkspaceGitSyncJob(
  WorkspaceGitSync sync, {
  required int intervalMinutes,
  bool enabled = true,
}) {
  return (
    job: ScheduledJob(
      id: workspaceGitSyncJobId,
      scheduleType: ScheduleType.interval,
      intervalMinutes: intervalMinutes,
      onExecute: () async {
        // The repo may not exist yet when sync was disabled at boot and enabled at runtime.
        await sync.initIfNeeded();
        await sync.commitAndPush();
        return 'workspace git sync ran (push ${sync.pushEnabled ? 'enabled' : 'disabled'})';
      },
    ),
    displayJob: {
      'name': workspaceGitSyncJobId,
      'schedule': 'every $intervalMinutes minutes',
      'delivery': 'none',
      'status': enabled ? 'active' : 'paused',
    },
  );
}
