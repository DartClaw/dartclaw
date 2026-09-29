import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart'
    show CompactionStartingEvent, EventBus, LoopDetectedEvent, TaskReviewReadyEvent, TurnWaitStateChangedEvent;

import 'sse_broadcast.dart';

/// Bridges selected [EventBus] events onto the global SSE broadcast channel.
///
/// This bridge intentionally excludes [EmergencyStopEvent]. Emergency-stop SSE
/// delivery remains owned by the imperative emit in `EmergencyStopHandler` so
/// wire output remains stable and avoids duplicate critical-stop frames.
class EventBusSseBridge {
  final StreamSubscription<LoopDetectedEvent> _loopDetectedSub;
  final StreamSubscription<TaskReviewReadyEvent> _taskReviewReadySub;
  final StreamSubscription<CompactionStartingEvent> _compactionStartingSub;
  final StreamSubscription<TurnWaitStateChangedEvent> _turnWaitStateSub;

  new({required EventBus bus, required SseBroadcast broadcast})
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
      _compactionStartingSub = bus.on<CompactionStartingEvent>().listen((event) {
        broadcast.broadcast('compaction_starting', {'sessionId': event.sessionId, 'trigger': event.trigger});
      }),
      _turnWaitStateSub = bus.on<TurnWaitStateChangedEvent>().listen((event) {
        broadcast.broadcast('conversation_changed', {
          'session_id': event.sessionId,
          'revision': event.timestamp.microsecondsSinceEpoch,
          'turn_id': event.turnId,
          'work_state': event.state.name,
        });
      });

  Future<void> cancel() async {
    await _loopDetectedSub.cancel();
    await _taskReviewReadySub.cancel();
    await _compactionStartingSub.cancel();
    await _turnWaitStateSub.cancel();
  }
}
