final class WorkflowStartPreconditionException implements Exception {
  final String message;

  const WorkflowStartPreconditionException(this.message);

  @override
  String toString() => message;
}
