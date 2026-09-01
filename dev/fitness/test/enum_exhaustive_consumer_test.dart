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
      'packages/dartclaw_runtime/lib/src/templates/workflow_detail.dart',
      'packages/dartclaw_runtime/lib/src/api/task_sse_routes.dart',
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
      'RunnerStateChangedEvent',
      'TaskStatusChangedEvent',
      'TaskReviewReadyEvent',
      'TaskEventCreatedEvent',
      'BudgetWarningEvent',
      'CompactionStartingEvent',
      'CompactionCompletedEvent',
      'SessionCreatedEvent',
      'SessionEndedEvent',
      'SessionErrorEvent',
      'LoopDetectedEvent',
      'EmergencyStopEvent',
      'ContainerStartedEvent',
      'ContainerStoppedEvent',
      'ContainerCrashedEvent',
      'AgentExecutionStatusChangedEvent',
      'CredentialHealthChangedEvent',
      'TurnWaitStateChangedEvent',
      'WorkflowCliStallEvent',
      'OutboundMcpGovernanceEvent',
      'ContextResearchMetricsEvent',
    ],
    // The classifier is the only DartclawEvent consumer in alerts/: it decides
    // an alert's type, severity and content together, so a new event type has
    // exactly one place that must consciously classify it (ADR-057).
    consumers: ['packages/dartclaw_runtime/lib/src/alerts/alert_classifier.dart'],
  ),
];

// A consumer that must stay exhaustive cannot carry a wildcard arm: `_ =>`
// compiles, keeps every test green, and silently reclassifies every future
// event value, which is the property ADR-057 keeps DartclawEvent sealed for.
const _wildcardFreeConsumers = ['packages/dartclaw_runtime/lib/src/alerts/alert_classifier.dart'];

// A file that cannot name a DartclawEvent subtype cannot switch on one. Alert
// rendering is downstream of classification and must stay event-blind.
const _eventBlindFiles = ['packages/dartclaw_runtime/lib/src/alerts/alert_formatter.dart'];

void main() {
  late String repoRoot;
  late Allowlist allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'enum_exhaustive_consumer.txt');
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'enum_exhaustive_consumer.txt'));
  });

  test('hardcoded enum consumers mention every status value', () {
    final violations = <String>[];

    for (final target in _targets) {
      for (final consumer in target.consumers) {
        final key = '$consumer:${target.enumName}';
        final content = File('$repoRoot/$consumer').readAsStringSync();
        for (final value in target.values) {
          final token = '${target.enumName}.$value';
          // Consulted only on a real gap, so an entry for a consumer that now
          // handles every value reads as stale instead of silent.
          if (!content.contains(token) && !allowlist.containsKey(key)) {
            violations.add('$token not handled in $consumer');
          }
        }
      }
    }
    for (final target in _eventTargets) {
      for (final consumer in target.consumers) {
        final key = '$consumer:${target.baseName}';
        final content = File('$repoRoot/$consumer').readAsStringSync();
        for (final value in target.values) {
          if (!content.contains(value) && !allowlist.containsKey(key)) {
            violations.add('$value not handled in $consumer');
          }
        }
      }
    }

    if (violations.isNotEmpty) {
      fail('Enum consumer exhaustiveness violations:\n  ${violations.join('\n  ')}');
    }
  });

  test('exhaustive event consumers carry no wildcard arm', () {
    for (final consumer in _wildcardFreeConsumers) {
      expect(
        File('$repoRoot/$consumer').readAsStringSync(),
        isNot(contains('_ =>')),
        reason:
            '$consumer must name every event explicitly. A `_ =>` arm turns "a new event must be '
            'classified" into "a new event is not an alert" with no compile error (ADR-057).',
      );
    }
  });

  test('event-blind files cannot name an event type', () {
    for (final file in _eventBlindFiles) {
      expect(
        File('$repoRoot/$file').readAsStringSync(),
        isNot(contains('package:dartclaw_core')),
        reason:
            '$file must not import dartclaw_core: with no DartclawEvent subtype in scope, no switch '
            'over an event can be reintroduced under any parameter name.',
      );
    }
  });
}
