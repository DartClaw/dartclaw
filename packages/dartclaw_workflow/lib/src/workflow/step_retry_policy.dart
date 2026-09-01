import 'workflow_definition.dart' show OnFailurePolicy;
import 'workflow_failure.dart' show WorkflowStepRetryFailure;

typedef WorkflowRetryLogger = void Function(int retryNumber, int retryLimit, WorkflowStepRetryFailure? failure);

/// Runs [dispatchAttempt] under the step's retry budget.
///
/// [failure] supplies the typed failure the caller chose for an attempt; two
/// consecutive equal values stop the loop early, before the budget is spent.
Future<T> runWithWorkflowRetry<T>({
  required OnFailurePolicy onFailure,
  required int maxRetries,
  required Future<T> Function(int attemptIndex) dispatchAttempt,
  required bool Function(T result) isFailedOutcome,
  required WorkflowStepRetryFailure? Function(T result) failure,
  WorkflowRetryLogger? onRetry,
}) async {
  final retryLimit = onFailure == OnFailurePolicy.retry ? maxRetries : 0;
  var attemptIndex = 0;
  WorkflowStepRetryFailure? previousFailure;

  while (true) {
    final result = await dispatchAttempt(attemptIndex);
    if (!isFailedOutcome(result) || attemptIndex >= retryLimit) {
      return result;
    }

    final attemptFailure = failure(result);
    if (attemptIndex > 0 && attemptFailure == previousFailure) {
      return result;
    }

    attemptIndex++;
    previousFailure = attemptFailure;
    onRetry?.call(attemptIndex, retryLimit, attemptFailure);
  }
}
