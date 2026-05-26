// Fitness function: selected enum/event consumers must enumerate every status value.
//
// How to resolve a failure:
//   Update the named consumer to handle the new enum value. If a consumer is
//   deliberately value-derived and does not enumerate values, add
//   `<file>:<EnumName>  # <rationale>` to enum_exhaustive_consumer.txt.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _targets = [
  (
    enumName: 'WorkflowRunStatus',
    values: ['pending', 'running', 'paused', 'awaitingApproval', 'completed', 'failed', 'cancelled'],
    consumers: [
      'packages/dartclaw_server/lib/src/templates/workflow_detail.dart',
      'packages/dartclaw_server/lib/src/api/task_sse_routes.dart',
      'packages/dartclaw_workflow/lib/src/workflow/workflow_view_helpers.dart',
      'apps/dartclaw_cli/lib/src/commands/workflow/workflow_run_command.dart',
      'apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart',
    ],
  ),
  (
    enumName: 'TaskStatus',
    values: ['draft', 'queued', 'running', 'interrupted', 'review', 'accepted', 'rejected', 'cancelled', 'failed'],
    consumers: ['packages/dartclaw_workflow/lib/src/workflow/workflow_view_helpers.dart'],
  ),
];

const _eventTargets = [
  (
    baseName: 'DartclawEvent',
    values: [
      'ProjectStatusChangedEvent',
      'WorkflowRunStatusChangedEvent',
      'WorkflowStepCompletedEvent',
      'WorkflowCliTurnProgressEvent',
      'ParallelGroupCompletedEvent',
      'WorkflowBudgetWarningEvent',
      'LoopIterationCompletedEvent',
      'MapIterationCompletedEvent',
      'WorkflowApprovalRequestedEvent',
      'WorkflowApprovalResolvedEvent',
      'MapStepCompletedEvent',
      'WorkflowSerializationEnactedEvent',
      'StepSkippedEvent',
      'FailedAuthEvent',
      'GuardBlockEvent',
      'ToolPermissionDeniedEvent',
      'ConfigChangedEvent',
      'ScheduledJobFailedEvent',
      'AgentStateChangedEvent',
      'TaskStatusChangedEvent',
      'TaskReviewReadyEvent',
      'TaskEventCreatedEvent',
      'BudgetWarningEvent',
      'CompactionStartingEvent',
      'CompactionCompletedEvent',
      'SessionCreatedEvent',
      'SessionEndedEvent',
      'SessionErrorEvent',
      'AdvisorMentionEvent',
      'AdvisorInsightEvent',
      'LoopDetectedEvent',
      'EmergencyStopEvent',
      'ContainerStartedEvent',
      'ContainerStoppedEvent',
      'ContainerCrashedEvent',
      'AgentExecutionStatusChangedEvent',
    ],
    consumers: [
      'packages/dartclaw_server/lib/src/alerts/alert_classifier.dart',
      'packages/dartclaw_server/lib/src/alerts/alert_formatter.dart',
    ],
  ),
];

void main() {
  late String repoRoot;
  late Map<String, String> allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'enum_exhaustive_consumer.txt');
  });

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(
      File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/enum_exhaustive_consumer.txt'),
    );
  });

  test('hardcoded enum consumers mention every status value', () {
    final violations = <String>[];

    for (final target in _targets) {
      for (final consumer in target.consumers) {
        final key = '$consumer:${target.enumName}';
        if (allowlist.containsKey(key)) continue;
        final content = File('$repoRoot/$consumer').readAsStringSync();
        for (final value in target.values) {
          final token = '${target.enumName}.$value';
          if (!content.contains(token)) {
            violations.add('$token not handled in $consumer');
          }
        }
      }
    }
    for (final target in _eventTargets) {
      for (final consumer in target.consumers) {
        final key = '$consumer:${target.baseName}';
        if (allowlist.containsKey(key)) continue;
        final content = File('$repoRoot/$consumer').readAsStringSync();
        for (final value in target.values) {
          if (!content.contains(value)) {
            violations.add('$value not handled in $consumer');
          }
        }
      }
    }

    if (violations.isNotEmpty) {
      fail('Enum consumer exhaustiveness violations:\n  ${violations.join('\n  ')}');
    }
  });
}
