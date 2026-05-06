import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart'
    show AdvisorInsightEvent, CompactionStartingEvent, EventBus, LoopDetectedEvent, TaskReviewReadyEvent;

import 'sse_broadcast.dart';

/// Bridges selected [EventBus] events onto the global SSE broadcast channel.
///
/// This bridge intentionally excludes [EmergencyStopEvent]. Emergency-stop SSE
/// delivery remains owned by the imperative emit in `EmergencyStopHandler` so
/// wire output remains stable and avoids duplicate critical-stop frames.
///
/// `AdvisorInsightEvent` global SSE delivery is intentionally additive to the
/// existing canvas push path.
class EventBusSseBridge {
  final StreamSubscription<LoopDetectedEvent> _loopDetectedSub;
  final StreamSubscription<TaskReviewReadyEvent> _taskReviewReadySub;
  final StreamSubscription<AdvisorInsightEvent> _advisorInsightSub;
  final StreamSubscription<CompactionStartingEvent> _compactionStartingSub;

  EventBusSseBridge({required EventBus bus, required SseBroadcast broadcast})
    : _loopDetectedSub = bus.on<LoopDetectedEvent>().listen((event) {
        broadcast.broadcast('loop_detected', {
          'sessionId': event.sessionId,
          'mechanism': event.mechanism,
          'message': event.message,
          'action': event.action,
          if (event.detail.isNotEmpty) 'detail': event.detail,
        });
      }),
      _taskReviewReadySub = bus.on<TaskReviewReadyEvent>().listen((event) {
        broadcast.broadcast('task_review_ready', {
          'taskId': event.taskId,
          'artifactCount': event.artifactCount,
          'artifactKinds': event.artifactKinds,
        });
      }),
      _advisorInsightSub = bus.on<AdvisorInsightEvent>().listen((event) {
        broadcast.broadcast('advisor_insight', {
          'status': event.status,
          'observation': event.observation,
          if (event.suggestion != null) 'suggestion': event.suggestion,
          'triggerType': event.triggerType,
          'taskIds': event.taskIds,
          'sessionKey': event.sessionKey,
        });
      }),
      _compactionStartingSub = bus.on<CompactionStartingEvent>().listen((event) {
        broadcast.broadcast('compaction_starting', {'sessionId': event.sessionId, 'trigger': event.trigger});
      });

  Future<void> cancel() async {
    await _loopDetectedSub.cancel();
    await _taskReviewReadySub.cancel();
    await _advisorInsightSub.cancel();
    await _compactionStartingSub.cancel();
  }
}
