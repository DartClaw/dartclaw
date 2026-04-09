import 'package:dartclaw_models/dartclaw_models.dart' show ProjectStatus, WorkflowRunStatus;

import '../task/task_status.dart';

part 'advisor_events.dart';
part 'agent_events.dart';
part 'auth_events.dart';
part 'compaction_events.dart';
part 'container_events.dart';
part 'governance_events.dart';
part 'project_events.dart';
part 'scheduling_events.dart';
part 'session_events.dart';
part 'task_events.dart';
part 'workflow_events.dart';

/// Sealed event hierarchy for the DartClaw internal event bus.
///
/// Events are ephemeral fire-and-forget notifications — identity-compared,
/// no `==`/`hashCode` overrides. Sealed classes enable exhaustive pattern
/// matching when new event types are added.
sealed class DartclawEvent {
  /// Timestamp when the event occurred.
  DateTime get timestamp;
}
