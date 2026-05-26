import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/api/event_bus_sse_bridge.dart';
import 'package:dartclaw_server/src/api/sse_broadcast.dart';
import 'package:test/test.dart';

Future<String> _nextFrame(StreamIterator<String> iterator) async {
  final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
  expect(hasFrame, isTrue);
  return iterator.current;
}

Map<String, dynamic> _decodeDataPayload(String frame) {
  final lines = frame.trim().split('\n');
  final dataLine = lines.firstWhere((line) => line.startsWith('data: '));
  return jsonDecode(dataLine.substring('data: '.length)) as Map<String, dynamic>;
}

String _decodeEventName(String frame) {
  final lines = frame.trim().split('\n');
  final eventLine = lines.firstWhere((line) => line.startsWith('event: '));
  return eventLine.substring('event: '.length);
}

void main() {
  late EventBus eventBus;
  late SseBroadcast broadcast;

  setUp(() {
    eventBus = EventBus();
    broadcast = SseBroadcast();
  });

  tearDown(() async {
    await eventBus.dispose();
    await broadcast.dispose();
  });

  test('bridges loop_detected, task_review_ready, advisor_insight, compaction_starting', () async {
    final client = broadcast.subscribe();
    final iterator = StreamIterator(client.stream.transform(utf8.decoder));
    addTearDown(iterator.cancel);

    final bridge = EventBusSseBridge(bus: eventBus, broadcast: broadcast);
    addTearDown(bridge.cancel);

    eventBus.fire(
      LoopDetectedEvent(
        sessionId: 's-1',
        mechanism: 'turnChainDepth',
        message: 'loop',
        action: 'abort',
        detail: const {'depth': 21},
        timestamp: DateTime.parse('2026-03-24T10:00:00Z'),
      ),
    );
    final loopFrame = await _nextFrame(iterator);
    expect(_decodeEventName(loopFrame), 'loop_detected');
    final loopPayload = _decodeDataPayload(loopFrame);
    expect(loopPayload['sessionId'], 's-1');
    expect(loopPayload['mechanism'], 'turnChainDepth');
    expect(loopPayload['action'], 'abort');

    eventBus.fire(
      TaskReviewReadyEvent(
        taskId: 't-1',
        artifactCount: 3,
        artifactKinds: const ['file_diff', 'console_log', 'plan'],
        timestamp: DateTime.parse('2026-03-24T10:00:01Z'),
      ),
    );
    final reviewFrame = await _nextFrame(iterator);
    expect(_decodeEventName(reviewFrame), 'task_review_ready');
    final reviewPayload = _decodeDataPayload(reviewFrame);
    expect(reviewPayload['taskId'], 't-1');
    expect(reviewPayload['artifactCount'], 3);
    expect(reviewPayload['artifactKinds'], ['file_diff', 'console_log', 'plan']);

    eventBus.fire(
      AdvisorInsightEvent(
        status: 'on_track',
        observation: 'all good',
        suggestion: 'keep going',
        triggerType: 'watchdog',
        taskIds: const ['t-1', 't-2'],
        sessionKey: 'agent:main:web:',
        timestamp: DateTime.parse('2026-03-24T10:00:02Z'),
      ),
    );
    final advisorFrame = await _nextFrame(iterator);
    expect(_decodeEventName(advisorFrame), 'advisor_insight');
    final advisorPayload = _decodeDataPayload(advisorFrame);
    expect(advisorPayload['status'], 'on_track');
    expect(advisorPayload['observation'], 'all good');
    expect(advisorPayload['triggerType'], 'watchdog');
    expect(advisorPayload['taskIds'], ['t-1', 't-2']);
    expect(advisorPayload['sessionKey'], 'agent:main:web:');

    eventBus.fire(
      CompactionStartingEvent(sessionId: 's-1', trigger: 'auto', timestamp: DateTime.parse('2026-03-24T10:00:03Z')),
    );
    final compactionFrame = await _nextFrame(iterator);
    expect(_decodeEventName(compactionFrame), 'compaction_starting');
    final compactionPayload = _decodeDataPayload(compactionFrame);
    expect(compactionPayload['sessionId'], 's-1');
    expect(compactionPayload['trigger'], 'auto');
  });

  test('does not emit emergency_stop from bridge', () async {
    final client = broadcast.subscribe();
    final iterator = StreamIterator(client.stream.transform(utf8.decoder));
    addTearDown(iterator.cancel);

    final bridge = EventBusSseBridge(bus: eventBus, broadcast: broadcast);
    addTearDown(bridge.cancel);

    eventBus.fire(
      EmergencyStopEvent(
        stoppedBy: 'admin',
        turnsCancelled: 2,
        tasksCancelled: 1,
        timestamp: DateTime.parse('2026-03-24T10:00:00Z'),
      ),
    );

    final hasFrame = await iterator.moveNext().timeout(const Duration(milliseconds: 150), onTimeout: () => false);
    expect(hasFrame, isFalse);
  });
}
