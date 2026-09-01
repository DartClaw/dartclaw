import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../behavior/heartbeat_job.dart';
import '../runtime_config.dart';
import '../scheduling/schedule_service.dart';
import '../workspace/workspace_git_sync.dart';
import '../workspace/workspace_git_sync_job.dart';

/// Applies the runtime side-effects of the three live scheduling/git-sync
/// switches, for both surfaces that flip them: the ephemeral toggle routes in
/// `api/config_routes.dart` and the `PATCH /api/config` change stream that
/// `ConfigChangeSubscriber` listens on.
///
/// Runtime state only. Persistence belongs to whoever called: the config PATCH
/// writes `dartclaw.yaml`, the toggle routes deliberately write nothing.
///
/// This is the **only** writer of `WorkspaceGitSync.pushEnabled` and of the
/// `RuntimeConfig` fields beside it. A persisted `workspace.*` reload reaches it
/// through [WorkspaceGitSyncReconfigurer] rather than writing the field itself,
/// so an ephemeral push toggle is still cleared by the next persisted
/// `workspace.*` write — deliberately, and with `RuntimeConfig` telling the
/// truth about it afterwards.
class RuntimeToggleApplier {
  final RuntimeConfig runtimeConfig;
  final ScheduleService? scheduleService;
  final WorkspaceGitSync? gitSync;

  new({required this.runtimeConfig, this.scheduleService, this.gitSync});

  /// `scheduling.heartbeat.enabled`.
  void setHeartbeatEnabled(bool enabled) {
    _setJobActive(heartbeatJobId, enabled);
    runtimeConfig.heartbeatEnabled = enabled;
  }

  /// `workspace.git_sync.enabled`.
  void setGitSyncEnabled(bool enabled) {
    _setJobActive(workspaceGitSyncJobId, enabled);
    runtimeConfig.gitSyncEnabled = enabled;
  }

  /// `workspace.git_sync.push_enabled`.
  void setGitSyncPushEnabled(bool enabled) {
    gitSync?.pushEnabled = enabled;
    runtimeConfig.gitSyncPushEnabled = enabled;
  }

  void _setJobActive(String jobId, bool active) {
    final service = scheduleService;
    if (service == null) return;
    if (active) {
      service.resumeJob(jobId);
    } else {
      service.pauseJob(jobId);
    }
  }
}

/// Routes a persisted `workspace.*` reload through [RuntimeToggleApplier].
///
/// Registered with `ConfigNotifier` in place of `WorkspaceGitSync` itself: the
/// sync object holds `pushEnabled`, the applier writes it, and `RuntimeConfig`
/// moves with it. Without this hop the reload wrote the field behind the
/// applier's back and `GET /api/settings/runtime` kept reporting the value the
/// applier had recorded rather than the one in force.
class WorkspaceGitSyncReconfigurer implements Reconfigurable {
  new(this._applier);

  final RuntimeToggleApplier _applier;

  @override
  Set<String> get watchKeys => const {'workspace.*'};

  @override
  void reconfigure(ConfigDelta delta) => _applier.setGitSyncPushEnabled(delta.current.workspace.gitSyncPushEnabled);
}
