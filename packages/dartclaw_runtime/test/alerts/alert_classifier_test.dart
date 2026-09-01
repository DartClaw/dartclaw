import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/alerts/alert_classifier.dart';
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

    test('LoopDetectedEvent → loop_detected / critical', () {
      final event = LoopDetectedEvent(
        sessionId: 'sess-1',
        mechanism: 'turnChainDepth',
        message: 'depth exceeded',
        action: 'abort',
        timestamp: _now,
      );
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'loop_detected');
      expect(result.severity, AlertSeverity.critical);
    });

    test('EmergencyStopEvent → emergency_stop / critical', () {
      final event = EmergencyStopEvent(stoppedBy: 'admin', turnsCancelled: 2, tasksCancelled: 1, timestamp: _now);
      final result = classifyAlert(event);
      expect(result, isNotNull);
      expect(result!.alertType, 'emergency_stop');
      expect(result.severity, AlertSeverity.critical);
    });

    test('unrecognized event types return null', () {
      // Use an event type that is not in the classifier mapping.
      final event = CompactionStartingEvent(sessionId: 'sess-1', trigger: 'auto', timestamp: _now);
      expect(classifyAlert(event), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // classifyAlert content – the body and detail fields an operator sees. These
  // strings are the shipped wording; they moved here from AlertFormatter and
  // are pinned literally so the move stayed byte-for-byte.
  // ---------------------------------------------------------------------------

  group('classifyAlert content', () {
    test('GuardBlockEvent carries guard, category, verdict, message and hook detail', () {
      final result = classifyAlert(
        GuardBlockEvent(
          guardName: 'bash-guard',
          guardCategory: 'file',
          verdict: 'block',
          verdictMessage: 'denied',
          hookPoint: 'PreToolUse',
          sessionKey: 'agent:main:web:',
          timestamp: _now,
        ),
      )!;
      expect(result.body, 'bash-guard (file): block — denied');
      expect(result.details, {'Hook': 'PreToolUse', 'Session': 'agent:main:web:'});
    });

    test('GuardBlockEvent without a verdict message or session key omits both', () {
      final result = classifyAlert(
        GuardBlockEvent(
          guardName: 'bash-guard',
          guardCategory: 'file',
          verdict: 'block',
          hookPoint: 'PreToolUse',
          timestamp: _now,
        ),
      )!;
      expect(result.body, 'bash-guard (file): block');
      expect(result.details, {'Hook': 'PreToolUse'});
    });

    test('ContainerCrashedEvent names the container and the error, with no details', () {
      final result = classifyAlert(
        ContainerCrashedEvent(profileId: 'p1', containerName: 'agent-box', error: 'OOM killed', timestamp: _now),
      )!;
      expect(result.body, 'agent-box: OOM killed');
      expect(result.details, isNull);
    });

    test('failed TaskStatusChangedEvent names the task and trigger', () {
      final result = classifyAlert(
        TaskStatusChangedEvent(
          taskId: 'task-1',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.failed,
          trigger: 'agent',
          timestamp: _now,
        ),
      )!;
      expect(result.body, 'Task task-1 failed (trigger: agent)');
      expect(result.details, {'Task ID': 'task-1', 'Trigger': 'agent'});
    });

    test('ScheduledJobFailedEvent names the job and the error', () {
      final result = classifyAlert(
        ScheduledJobFailedEvent(jobId: 'daily-backup', jobName: 'daily-backup', error: 'timed out', timestamp: _now),
      )!;
      expect(result.body, 'Job daily-backup: timed out');
      expect(result.details, {'Job ID': 'daily-backup'});
    });

    test('BudgetWarningEvent renders consumed/limit and a rounded percentage', () {
      final result = classifyAlert(
        BudgetWarningEvent(taskId: 'task-99', consumedPercent: 0.9, consumed: 90000, limit: 100000, timestamp: _now),
      )!;
      expect(result.body, 'Task task-99: 90000/100000 tokens (90%)');
      expect(result.details, {'Task ID': 'task-99'});
    });

    test('WorkflowBudgetWarningEvent renders the run instead of the task', () {
      final result = classifyAlert(
        WorkflowBudgetWarningEvent(
          runId: 'run-42',
          definitionName: 'my-flow',
          consumedPercent: 0.8,
          consumed: 80000,
          limit: 100000,
          timestamp: _now,
        ),
      )!;
      expect(result.body, 'Workflow run run-42: 80000/100000 tokens (80%)');
      expect(result.details, {'Run ID': 'run-42', 'Workflow': 'my-flow'});
    });

    test('CompactionCompletedEvent appends pre-compaction tokens only when known', () {
      final withTokens = classifyAlert(
        CompactionCompletedEvent(sessionId: 'sess-7', trigger: 'auto', preTokens: 50000, timestamp: _now),
      )!;
      expect(withTokens.body, 'Session sess-7 compacted (trigger: auto, pre: 50000 tokens)');
      expect(withTokens.details, {'Session ID': 'sess-7', 'Trigger': 'auto'});

      final withoutTokens = classifyAlert(
        CompactionCompletedEvent(sessionId: 'sess-7', trigger: 'auto', timestamp: _now),
      )!;
      expect(withoutTokens.body, 'Session sess-7 compacted (trigger: auto)');
    });

    test('LoopDetectedEvent names the session, mechanism and action', () {
      final result = classifyAlert(
        LoopDetectedEvent(
          sessionId: 'sess-1',
          mechanism: 'turnChainDepth',
          message: 'depth exceeded',
          action: 'abort',
          timestamp: _now,
        ),
      )!;
      expect(result.body, 'Loop detected in session sess-1 (mechanism: turnChainDepth, action: abort)');
      expect(result.details, {'Session': 'sess-1', 'Mechanism': 'turnChainDepth', 'Action': 'abort'});
    });

    test('EmergencyStopEvent names the actor and both counters', () {
      final result = classifyAlert(
        EmergencyStopEvent(stoppedBy: 'admin', turnsCancelled: 2, tasksCancelled: 1, timestamp: _now),
      )!;
      expect(result.body, 'Emergency stop by admin — 2 turn(s), 1 task(s) cancelled');
      expect(result.details, {'Stopped by': 'admin', 'Turns cancelled': '2', 'Tasks cancelled': '1'});
    });

    test('a non-alertable event classifies null and so has no content at all', () {
      expect(classifyAlert(SessionEndedEvent(sessionId: 'sess-1', sessionType: 'web', timestamp: _now)), isNull);
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
