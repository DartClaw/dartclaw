import 'dart:convert';

import 'outbound_mcp_errors.dart';

Map<String, dynamic> decodeJsonRpcResponse(String body, {required int expectedId, required int maxResponseBytes}) {
  if (utf8.encode(body).length > maxResponseBytes) {
    throw const OutboundMcpException('response_too_large', 'MCP response exceeded receive size limit');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    throw OutboundMcpException('malformed_response', 'Malformed MCP JSON-RPC response: ${error.message}');
  }
  if (decoded is! Map) {
    throw const OutboundMcpException('malformed_response', 'MCP JSON-RPC response must be an object');
  }
  final response = Map<String, dynamic>.from(decoded);
  _validateResponseEnvelope(response, expectedId: expectedId);
  final rpcError = response['error'];
  if (rpcError is Map) {
    final message = rpcError['message']?.toString() ?? 'MCP JSON-RPC error';
    throw OutboundMcpException('protocol_error', message);
  }
  final result = response['result'];
  if (result is Map<String, dynamic>) return result;
  if (result is Map) return Map<String, dynamic>.from(result);
  throw const OutboundMcpException('malformed_response', 'MCP JSON-RPC result must be an object');
}

String encodeJsonRpcRequest(int id, String method, Map<String, dynamic> params) {
  return jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
}

String encodeJsonRpcNotification(String method, Map<String, dynamic> params) {
  return jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params});
}

bool isJsonRpcServerMessage(String body, {required int maxResponseBytes}) {
  if (utf8.encode(body).length > maxResponseBytes) {
    throw const OutboundMcpException('response_too_large', 'MCP response exceeded receive size limit');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    throw OutboundMcpException('malformed_response', 'Malformed MCP JSON-RPC response: ${error.message}');
  }
  if (decoded is! Map) {
    throw const OutboundMcpException('malformed_response', 'MCP JSON-RPC response must be an object');
  }
  final message = Map<String, dynamic>.from(decoded);
  return message['jsonrpc'] == '2.0' &&
      message['method'] is String &&
      !message.containsKey('result') &&
      !message.containsKey('error');
}

void _validateResponseEnvelope(Map<String, dynamic> response, {required int expectedId}) {
  if (response['jsonrpc'] != '2.0') {
    throw const OutboundMcpException('malformed_response', 'MCP JSON-RPC response must declare jsonrpc 2.0');
  }
  if (response['id'] != expectedId) {
    throw const OutboundMcpException('malformed_response', 'MCP JSON-RPC response id did not match the request');
  }
  final hasResult = response.containsKey('result');
  final hasError = response.containsKey('error');
  if (hasResult == hasError) {
    throw const OutboundMcpException(
      'malformed_response',
      'MCP JSON-RPC response must contain exactly one of result or error',
    );
  }
  if (hasError && response['error'] is! Map) {
    throw const OutboundMcpException('malformed_response', 'MCP JSON-RPC error must be an object');
  }
}
