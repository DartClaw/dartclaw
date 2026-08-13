final class WorkflowStartPreconditionException implements Exception {
  final String message;

  const new(this.message);

  @override
  String toString() => message;
}
