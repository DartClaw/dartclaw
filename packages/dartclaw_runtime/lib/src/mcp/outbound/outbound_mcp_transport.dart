import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'outbound_mcp_models.dart';

/// Transport primitive used by the outbound MCP protocol client.
abstract interface class OutboundMcpTransport {
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  });

  Future<void> sendNotification(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  });

  Future<bool> ping({required Duration timeout, required int maxResponseBytes});

  Future<void> close();
}

typedef OutboundMcpTransportFactory = Future<OutboundMcpTransport> Function(
  OutboundMcpServerDefinition server,
  OutboundMcpTransportOptions options,
);

final class OutboundMcpTransportOptions {
  final Duration timeout;
  final int maxResponseBytes;
  final CredentialEntry? credential;

  const new({required this.timeout, required this.maxResponseBytes, this.credential});
}
