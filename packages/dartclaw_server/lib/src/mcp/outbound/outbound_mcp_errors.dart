/// Exception used internally before mapping failures to caller-visible errors.
final class OutboundMcpException implements Exception {
  final String code;
  final String message;

  const OutboundMcpException(this.code, this.message);

  @override
  String toString() => 'OutboundMcpException($code, $message)';
}
