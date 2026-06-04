import 'workflow_definition.dart' show OnFailurePolicy;

typedef WorkflowRetryLogger = void Function(int retryNumber, int retryLimit, String? failureClass);

Future<T> runWithWorkflowRetry<T>({
  required OnFailurePolicy onFailure,
  required int maxRetries,
  required Future<T> Function(int attemptIndex) dispatchAttempt,
  required bool Function(T result) isFailedOutcome,
  required String? Function(T result) failureReason,
  WorkflowRetryLogger? onRetry,
}) async {
  final retryLimit = onFailure == OnFailurePolicy.retry ? maxRetries : 0;
  var attemptIndex = 0;
  String? previousFailureClass;

  while (true) {
    final result = await dispatchAttempt(attemptIndex);
    if (!isFailedOutcome(result) || attemptIndex >= retryLimit) {
      return result;
    }

    final failureClass = workflowRetryFailureClass(failureReason(result));
    if (previousFailureClass != null && failureClass == previousFailureClass) {
      return result;
    }

    attemptIndex++;
    previousFailureClass = failureClass;
    onRetry?.call(attemptIndex, retryLimit, failureClass);
  }
}

String workflowRetryFailureClass(String? errorSummary) {
  var normalized = (errorSummary == null || errorSummary.trim().isEmpty ? 'workflow step failed' : errorSummary)
      .toLowerCase()
      .trim();
  for (final prefix in const [
    'exception: ',
    'stateerror: ',
    'bad state: ',
    'argumenterror: ',
    'invalid argument(s): ',
  ]) {
    if (normalized.startsWith(prefix)) {
      normalized = normalized.substring(prefix.length).trim();
      break;
    }
  }
  final classEnd = normalized.indexOf(RegExp(r'[:(\[]'));
  if (classEnd > 0) normalized = normalized.substring(0, classEnd).trim();
  if (normalized.length > 80) normalized = normalized.substring(0, 80);
  return normalized.isEmpty ? 'workflow step failed' : normalized;
}
