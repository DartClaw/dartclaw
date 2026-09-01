import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/alerts/alert_classifier.dart';
import 'package:dartclaw_runtime/src/alerts/alert_formatter.dart';
import 'package:test/test.dart';

DateTime get _now => DateTime.now();

const _formatter = AlertFormatter();

void main() {
  group('AlertFormatter plain text (non-Google Chat)', () {
    for (final channelType in ['whatsapp', 'signal', 'unknown']) {
      test('$channelType: GuardBlockEvent produces plain text with guard name and verdict', () {
        final event = GuardBlockEvent(
          guardName: 'bash-guard',
          guardCategory: 'file',
          verdict: 'block',
          hookPoint: 'PreToolUse',
          timestamp: _now,
        );
        final response = _formatter.format(classification: classifyAlert(event)!, channelType: channelType);

        expect(response.text, contains('bash-guard'));
        expect(response.text, contains('block'));
        expect(response.text, contains('[WARNING]'));
        expect(response.structuredPayload, isNull);
      });
    }

    // Every alert type the classifier can produce needs a title arm: the
    // wildcard falls through to the raw type, so an operator reads
    // "[CRITICAL] emergency_stop:" instead of a sentence.
    test('every classifiable alert type renders a titled heading, not its raw type', () {
      final events = <DartclawEvent>[
        EmergencyStopEvent(stoppedBy: 'web session', turnsCancelled: 1, tasksCancelled: 2, timestamp: DateTime.now()),
        LoopDetectedEvent(
          sessionId: 's',
          mechanism: 'turnChainDepth',
          message: 'chain too deep',
          action: 'abort',
          timestamp: DateTime.now(),
        ),
      ];

      for (final event in events) {
        final classification = classifyAlert(event)!;
        final response = _formatter.format(classification: classification, channelType: 'whatsapp');
        expect(
          response.text,
          isNot(contains(classification.alertType)),
          reason: 'the raw snake_case type reached the operator for ${event.runtimeType}',
        );
      }
    });

    test('whatsapp: ScheduledJobFailedEvent produces plain text with job ID and error', () {
      final event = ScheduledJobFailedEvent(
        jobId: 'daily-backup',
        jobName: 'daily-backup',
        error: 'connection refused',
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'whatsapp');

      expect(response.text, contains('daily-backup'));
      expect(response.text, contains('connection refused'));
      expect(response.text, contains('[CRITICAL]'));
      expect(response.structuredPayload, isNull);
    });

    test('signal: ContainerCrashedEvent produces plain text with container name and error', () {
      final event = ContainerCrashedEvent(
        profileId: 'p1',
        containerName: 'agent-box',
        error: 'OOM killed',
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'signal');

      expect(response.text, contains('agent-box'));
      expect(response.text, contains('OOM killed'));
      expect(response.structuredPayload, isNull);
    });

    test('BudgetWarningEvent produces plain text with task ID and token info', () {
      final event = BudgetWarningEvent(
        taskId: 'task-99',
        consumedPercent: 0.9,
        consumed: 90000,
        limit: 100000,
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'whatsapp');

      expect(response.text, contains('task-99'));
      expect(response.text, contains('90000'));
      expect(response.text, contains('100000'));
    });

    test('WorkflowBudgetWarningEvent produces plain text with run ID', () {
      final event = WorkflowBudgetWarningEvent(
        runId: 'run-42',
        definitionName: 'my-flow',
        consumedPercent: 0.8,
        consumed: 80000,
        limit: 100000,
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'signal');

      expect(response.text, contains('run-42'));
    });

    test('CompactionCompletedEvent produces plain text with session ID', () {
      final event = CompactionCompletedEvent(sessionId: 'sess-7', trigger: 'auto', timestamp: _now);
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'whatsapp');

      expect(response.text, contains('sess-7'));
      expect(response.text, contains('[INFO]'));
    });

    test('LoopDetectedEvent includes [CRITICAL], session and mechanism in body + details', () {
      final event = LoopDetectedEvent(
        sessionId: 'sess-1',
        mechanism: 'turnChainDepth',
        message: 'loop detected',
        action: 'abort',
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      expect(response.text, contains('[CRITICAL]'));
      expect(response.text, contains('sess-1'));
      expect(response.text, contains('turnChainDepth'));
      final payload = response.structuredPayload as Map<String, dynamic>;
      expect(payload.toString(), contains('Session'));
      expect(payload.toString(), contains('Mechanism'));
      expect(payload.toString(), contains('Action'));
    });

    test('EmergencyStopEvent includes [CRITICAL], actor and counters in body + details', () {
      final event = EmergencyStopEvent(stoppedBy: 'admin', turnsCancelled: 2, tasksCancelled: 1, timestamp: _now);
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      expect(response.text, contains('[CRITICAL]'));
      expect(response.text, contains('admin'));
      expect(response.text, contains('2'));
      expect(response.text, contains('1'));
      final payload = response.structuredPayload as Map<String, dynamic>;
      expect(payload.toString(), contains('Stopped by'));
      expect(payload.toString(), contains('Turns cancelled'));
      expect(payload.toString(), contains('Tasks cancelled'));
    });
  });

  group('AlertFormatter Google Chat', () {
    test('GuardBlockEvent returns ChannelResponse with structuredPayload containing cardsV2', () {
      final event = GuardBlockEvent(
        guardName: 'bash-guard',
        guardCategory: 'file',
        verdict: 'warn',
        hookPoint: 'PostToolUse',
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      expect(response.text, contains('bash-guard'));
      expect(response.structuredPayload, isNotNull);
      final payload = response.structuredPayload as Map<String, dynamic>;
      expect(payload['cardsV2'], isA<List<dynamic>>());
      expect((payload['cardsV2'] as List<dynamic>).length, 1);
    });

    test('ScheduledJobFailedEvent Google Chat card includes severity-colored critical badge', () {
      final event = ScheduledJobFailedEvent(
        jobId: 'nightly-sync',
        jobName: 'nightly-sync',
        error: 'timeout',
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      expect(response.structuredPayload, isNotNull);
      final payload = response.structuredPayload as Map<String, dynamic>;
      final cardStr = payload.toString();
      // Critical color #d93025 should appear in the card
      expect(cardStr, contains('#d93025'));
    });

    test('warning severity card uses amber color #f9ab00', () {
      final event = BudgetWarningEvent(
        taskId: 'task-1',
        consumedPercent: 0.9,
        consumed: 90000,
        limit: 100000,
        timestamp: _now,
      );
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      final payload = response.structuredPayload as Map<String, dynamic>;
      expect(payload.toString(), contains('#f9ab00'));
    });

    test('info severity card uses blue color #1a73e8', () {
      final event = CompactionCompletedEvent(sessionId: 'sess-1', trigger: 'auto', timestamp: _now);
      final response = _formatter.format(classification: classifyAlert(event)!, channelType: 'googlechat');

      final payload = response.structuredPayload as Map<String, dynamic>;
      expect(payload.toString(), contains('#1a73e8'));
    });

    test('all 6 event types produce distinct formatted output', () {
      final events = <DartclawEvent>[
        GuardBlockEvent(
          guardName: 'g1',
          guardCategory: 'c1',
          verdict: 'block',
          hookPoint: 'PreToolUse',
          timestamp: _now,
        ),
        ContainerCrashedEvent(profileId: 'p1', containerName: 'c1', error: 'e1', timestamp: _now),
        TaskStatusChangedEvent(
          taskId: 't1',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.failed,
          trigger: 'agent',
          timestamp: _now,
        ),
        ScheduledJobFailedEvent(jobId: 'j1', jobName: 'j1', error: 'err', timestamp: _now),
        BudgetWarningEvent(taskId: 'tbudget', consumedPercent: 0.8, consumed: 80000, limit: 100000, timestamp: _now),
        CompactionCompletedEvent(sessionId: 'sess-c', trigger: 'auto', timestamp: _now),
      ];

      final texts = <String>{};
      for (final event in events) {
        texts.add(_formatter.format(classification: classifyAlert(event)!, channelType: 'whatsapp').text);
      }

      // All 6 should produce distinct text outputs.
      expect(texts.length, 6);
    });
  });
}
