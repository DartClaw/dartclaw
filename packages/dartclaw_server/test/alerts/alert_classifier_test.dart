import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/alerts/alert_classifier.dart';
import 'package:test/test.dart';

DateTime get _now => DateTime.now();

void main() {
  // ---------------------------------------------------------------------------
  // classifyAlert
  // ---------------------------------------------------------------------------

  group('classifyAlert', () {
    test('GuardBlockEvent → guard_block / warning', () {
      final event = GuardBlockEvent(
        guardName: 'bash-guard',
        guardCategory: 'file',
        verdict: 'block',
        hookPoint: 'PreToolUse',
        timestamp: _now,
      );
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'guard_block');
      expect(result.severity, AlertSeverity.warning);
    });

    test('ContainerCrashedEvent → container_crash / critical', () {
      final event = ContainerCrashedEvent(
        profileId: 'p1',
        containerName: 'agent-container',
        error: 'OOM killed',
        timestamp: _now,
      );
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'container_crash');
      expect(result.severity, AlertSeverity.critical);
    });

    test('TaskStatusChangedEvent with failed → task_failure / warning', () {
      final event = TaskStatusChangedEvent(
        taskId: 'task-1',
        oldStatus: TaskStatus.running,
        newStatus: TaskStatus.failed,
        trigger: 'agent',
        timestamp: _now,
      );
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'task_failure');
      expect(result.severity, AlertSeverity.warning);
    });

    test('TaskStatusChangedEvent with non-failed status returns null', () {
      for (final status in [TaskStatus.running, TaskStatus.review, TaskStatus.accepted, TaskStatus.rejected]) {
        final event = TaskStatusChangedEvent(
          taskId: 'task-1',
          oldStatus: TaskStatus.running,
          newStatus: status,
          trigger: 'agent',
          timestamp: _now,
        );
        expect(classifyAlert(event), isNull, reason: 'status: $status');
      }
    });

    test('ScheduledJobFailedEvent → job_failure / critical', () {
      final event = ScheduledJobFailedEvent(jobId: 'my-job', jobName: 'my-job', error: 'timed out', timestamp: _now);
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'job_failure');
      expect(result.severity, AlertSeverity.critical);
    });

    test('BudgetWarningEvent → budget_warning / warning', () {
      final event = BudgetWarningEvent(
        taskId: 'task-2',
        consumedPercent: 0.9,
        consumed: 90000,
        limit: 100000,
        timestamp: _now,
      );
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'budget_warning');
      expect(result.severity, AlertSeverity.warning);
    });

    test('WorkflowBudgetWarningEvent → budget_warning / warning', () {
      final event = WorkflowBudgetWarningEvent(
        runId: 'run-1',
        definitionName: 'my-workflow',
        consumedPercent: 0.8,
        consumed: 80000,
        limit: 100000,
        timestamp: _now,
      );
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'budget_warning');
      expect(result.severity, AlertSeverity.warning);
    });

    test('CompactionCompletedEvent → compaction / info', () {
      final event = CompactionCompletedEvent(sessionId: 'sess-1', trigger: 'auto', timestamp: _now);
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'compaction');
      expect(result.severity, AlertSeverity.info);
    });

    test('unrecognized event types return null', () {
      // Use an event type that is not in the classifier mapping.
      final event = CompactionStartingEvent(sessionId: 'sess-1', trigger: 'auto', timestamp: _now);
      expect(classifyAlert(event), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // shouldAlertTaskFailure
  // ---------------------------------------------------------------------------

  group('shouldAlertTaskFailure', () {
    Map<String, dynamic> configWithOrigin(String sessionKey) => {
      'origin': {'channelType': 'whatsapp', 'sessionKey': sessionKey, 'recipientId': '+1000'},
    };

    test('no TaskOrigin (empty configJson) → should alert', () {
      expect(shouldAlertTaskFailure({}), isTrue);
    });

    test('TaskOrigin with scope dm → suppress', () {
      expect(shouldAlertTaskFailure(configWithOrigin('agent:main:dm:+1234')), isFalse);
    });

    test('TaskOrigin with scope group → suppress', () {
      expect(shouldAlertTaskFailure(configWithOrigin('agent:main:group:space123')), isFalse);
    });

    test('TaskOrigin with scope web → should alert', () {
      expect(shouldAlertTaskFailure(configWithOrigin('agent:main:web:')), isTrue);
    });

    test('TaskOrigin with scope cron → should alert', () {
      expect(shouldAlertTaskFailure(configWithOrigin('agent:main:cron:my-job')), isTrue);
    });

    test('TaskOrigin with scope task → should alert', () {
      expect(shouldAlertTaskFailure(configWithOrigin('agent:main:task:task-1')), isTrue);
    });

    test('malformed sessionKey → fail-open, should alert', () {
      expect(shouldAlertTaskFailure(configWithOrigin('not-a-valid-key')), isTrue);
    });
  });
}
