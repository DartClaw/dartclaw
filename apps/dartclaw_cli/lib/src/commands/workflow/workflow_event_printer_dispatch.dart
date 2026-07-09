import 'package:dartclaw_core/dartclaw_core.dart' show MapIterationCompletedEvent, WorkflowStepCompletedEvent;

import 'cli_progress_printer.dart';

void dispatchWorkflowStepCompletedToPrinter({
  required CliProgressPrinter printer,
  required WorkflowStepCompletedEvent event,
  required Duration? duration,
  required String progressKey,
}) {
  final outcome = event.outcome;
  if (outcome == 'succeeded') {
    printer.stepCompleted(
      event.stepIndex,
      event.stepId,
      duration,
      event.tokenCount,
      displayScope: event.displayScope,
      progressKey: progressKey,
    );
  } else if (_isBlockedOutcome(outcome)) {
    printer.stepBlocked(
      event.stepIndex,
      event.stepId,
      event.reason,
      displayScope: event.displayScope,
      progressKey: progressKey,
    );
  } else if (outcome == 'cancelled') {
    printer.stepInterrupted(
      event.stepIndex,
      event.stepId,
      event.reason,
      displayScope: event.displayScope,
      progressKey: progressKey,
    );
  } else if (outcome == 'failed' || !event.success) {
    printer.stepFailed(
      event.stepIndex,
      event.stepId,
      event.reason,
      displayScope: event.displayScope,
      progressKey: progressKey,
    );
  } else {
    printer.stepCompleted(
      event.stepIndex,
      event.stepId,
      duration,
      event.tokenCount,
      displayScope: event.displayScope,
      progressKey: progressKey,
    );
  }
}

void dispatchMapIterationCompletedToPrinter({
  required CliProgressPrinter printer,
  required MapIterationCompletedEvent event,
  required int stepIndex,
  required Duration? duration,
  required String progressKey,
  String? displayScope,
}) {
  final scope = displayScope ?? event.itemId;
  final outcome = event.outcome;
  if (outcome == 'succeeded') {
    printer.stepCompleted(
      stepIndex,
      event.stepId,
      duration,
      event.tokenCount,
      displayScope: scope,
      progressKey: progressKey,
    );
  } else if (_isBlockedOutcome(outcome)) {
    printer.stepBlocked(stepIndex, event.stepId, event.reason, displayScope: scope, progressKey: progressKey);
  } else if (outcome == 'cancelled') {
    printer.stepInterrupted(stepIndex, event.stepId, event.reason, displayScope: scope, progressKey: progressKey);
  } else if (outcome == 'failed' || !event.success) {
    printer.stepFailed(stepIndex, event.stepId, event.reason, displayScope: scope, progressKey: progressKey);
  } else {
    printer.stepCompleted(
      stepIndex,
      event.stepId,
      duration,
      event.tokenCount,
      displayScope: scope,
      progressKey: progressKey,
    );
  }
}

bool _isBlockedOutcome(String? outcome) => outcome == 'needsInput' || outcome == 'blocked';
