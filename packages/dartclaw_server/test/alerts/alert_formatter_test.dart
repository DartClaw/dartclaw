import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/alerts/alert_classifier.dart';
import 'package:dartclaw_server/src/alerts/alert_formatter.dart';
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
        final response = _formatter.format(
          event: event,
          alertType: 'guard_block',
          severity: AlertSeverity.warning,
          channelType: channelType,
        );

        expect(response.text, contains('bash-guard'));
        expect(response.text, contains('block'));
        expect(response.text, contains('[WARNING]'));
        expect(response.structuredPayload, isNull);
      });
    }

    test('whatsapp: ScheduledJobFailedEvent produces plain text with job ID and error', () {
      final event = ScheduledJobFailedEvent(
        jobId: 'daily-backup',
        jobName: 'daily-backup',
        error: 'connection refused',
        timestamp: _now,
      );
      final response = _formatter.format(
        event: event,
        alertType: 'job_failure',
        severity: AlertSeverity.critical,
        channelType: 'whatsapp',
      );

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
      final response = _formatter.format(
        event: event,
        alertType: 'container_crash',
        severity: AlertSeverity.critical,
        channelType: 'signal',
      );

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
      final response = _formatter.format(
        event: event,
        alertType: 'budget_warning',
        severity: AlertSeverity.warning,
        channelType: 'whatsapp',
      );

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
      final response = _formatter.format(
        event: event,
        alertType: 'budget_warning',
        severity: AlertSeverity.warning,
        channelType: 'signal',
      );

      expect(response.text, contains('run-42'));
    });

    test('CompactionCompletedEvent produces plain text with session ID', () {
      final event = CompactionCompletedEvent(sessionId: 'sess-7', trigger: 'auto', timestamp: _now);
      final response = _formatter.format(
        event: event,
        alertType: 'compaction',
        severity: AlertSeverity.info,
        channelType: 'whatsapp',
      );

      expect(response.text, contains('sess-7'));
      expect(response.text, contains('[INFO]'));
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
      final response = _formatter.format(
        event: event,
        alertType: 'guard_block',
        severity: AlertSeverity.warning,
        channelType: 'googlechat',
      );

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
      final response = _formatter.format(
        event: event,
        alertType: 'job_failure',
        severity: AlertSeverity.critical,
        channelType: 'googlechat',
      );

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
      final response = _formatter.format(
        event: event,
        alertType: 'budget_warning',
        severity: AlertSeverity.warning,
        channelType: 'googlechat',
      );

      final payload = response.structuredPayload as Map<String, dynamic>;
      expect(payload.toString(), contains('#f9ab00'));
    });

    test('info severity card uses blue color #1a73e8', () {
      final event = CompactionCompletedEvent(sessionId: 'sess-1', trigger: 'auto', timestamp: _now);
      final response = _formatter.format(
        event: event,
        alertType: 'compaction',
        severity: AlertSeverity.info,
        channelType: 'googlechat',
      );

      final payload = response.structuredPayload as Map<String, dynamic>;
      expect(payload.toString(), contains('#1a73e8'));
    });

    test('all 6 event types produce distinct formatted output', () {
      final events = <({DartclawEvent event, String alertType, AlertSeverity severity})>[
        (
          event: GuardBlockEvent(
            guardName: 'g1',
            guardCategory: 'c1',
            verdict: 'block',
            hookPoint: 'PreToolUse',
            timestamp: _now,
          ),
          alertType: 'guard_block',
          severity: AlertSeverity.warning,
        ),
        (
          event: ContainerCrashedEvent(profileId: 'p1', containerName: 'c1', error: 'e1', timestamp: _now),
          alertType: 'container_crash',
          severity: AlertSeverity.critical,
        ),
        (
          event: TaskStatusChangedEvent(
            taskId: 't1',
            oldStatus: TaskStatus.running,
            newStatus: TaskStatus.failed,
            trigger: 'agent',
            timestamp: _now,
          ),
          alertType: 'task_failure',
          severity: AlertSeverity.warning,
        ),
        (
          event: ScheduledJobFailedEvent(jobId: 'j1', jobName: 'j1', error: 'err', timestamp: _now),
          alertType: 'job_failure',
          severity: AlertSeverity.critical,
        ),
        (
          event: BudgetWarningEvent(
            taskId: 'tbudget',
            consumedPercent: 0.8,
            consumed: 80000,
            limit: 100000,
            timestamp: _now,
          ),
          alertType: 'budget_warning',
          severity: AlertSeverity.warning,
        ),
        (
          event: CompactionCompletedEvent(sessionId: 'sess-c', trigger: 'auto', timestamp: _now),
          alertType: 'compaction',
          severity: AlertSeverity.info,
        ),
      ];

      final texts = <String>{};
      for (final e in events) {
        final response = _formatter.format(
          event: e.event,
          alertType: e.alertType,
          severity: e.severity,
          channelType: 'whatsapp',
        );
        texts.add(response.text);
      }

      // All 6 should produce distinct text outputs.
      expect(texts.length, 6);
    });
  });
}
