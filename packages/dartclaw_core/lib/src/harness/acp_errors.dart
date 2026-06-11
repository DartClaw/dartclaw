/// Structured ACP harness failure codes.
enum AcpHarnessErrorCode {
  /// The configured ACP binary could not be spawned.
  spawnFailed('SPAWN_FAILED'),

  /// ACP initialize failed.
  initFailed('ACP_INIT_FAILED'),

  /// ACP agent requires interactive authentication.
  authRequired('ACP_AUTH_REQUIRED'),

  /// ACP subprocess exited unexpectedly.
  processExited('ACP_PROCESS_EXITED'),

  /// ACP session close failed.
  closeFailed('ACP_CLOSE_FAILED');

  /// Stable operator-visible code.
  final String code;

  const AcpHarnessErrorCode(this.code);
}

/// Structured exception raised by [AcpHarness] lifecycle failures.
final class AcpHarnessException implements Exception {
  /// Stable operator-visible code.
  final AcpHarnessErrorCode errorCode;

  /// Human-readable failure summary.
  final String message;

  /// Captured stdout/stderr or protocol diagnostics.
  final Map<String, Object?> diagnostics;

  /// Creates an ACP harness exception.
  const AcpHarnessException(this.errorCode, this.message, {this.diagnostics = const <String, Object?>{}});

  /// Stable operator-visible code string.
  String get code => errorCode.code;

  @override
  String toString() => '${errorCode.code}: $message${diagnostics.isEmpty ? '' : ' $diagnostics'}';
}
