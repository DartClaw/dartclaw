import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Maximum webhook payload size (1 MiB). Rejects oversized POST bodies
/// on unauthenticated webhook endpoints to prevent OOM attacks.
const maxWebhookPayloadBytes = 1024 * 1024;

/// Constant-time string comparison to prevent timing attacks on secrets.
///
/// Returns true only if [a] and [b] are equal, but takes the same amount
/// of time regardless of where (or whether) they differ — preventing
/// attackers from inferring correct characters via response-time analysis.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return result == 0;
}

/// Reads a request body up to [limit] bytes, returning `null` if exceeded.
///
/// Checks `Content-Length` header first for a fast 413 rejection path,
/// then caps the stream read for chunked/missing-header cases.
Future<String?> readBounded(Request request, int limit) async {
  final contentLength = request.contentLength;
  if (contentLength != null && contentLength > limit) return null;

  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > limit) return null;
  }
  return utf8.decode(bytes);
}
