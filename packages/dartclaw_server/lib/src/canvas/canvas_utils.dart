import 'dart:convert';
import 'dart:math';

/// Encodes an SSE frame with event name and JSON payload.
List<int> sseFrame(String event, Map<String, dynamic> payload) {
  return utf8.encode('event: $event\ndata: ${jsonEncode(payload)}\n\n');
}

/// Parses duration shorthand strings like "30m", "8h", "1d".
/// Defaults to minutes when no unit suffix is present.
Duration? parseDuration(String raw) {
  final match = RegExp(r'^(\d+)([smhd])?$').firstMatch(raw.toLowerCase());
  if (match == null) return null;
  final amount = int.tryParse(match.group(1)!);
  if (amount == null) return null;
  final unit = match.group(2) ?? 'm';
  return switch (unit) {
    's' => Duration(seconds: amount),
    'm' => Duration(minutes: amount),
    'h' => Duration(hours: amount),
    'd' => Duration(days: amount),
    _ => null,
  };
}

/// Generates a cryptographic nonce for CSP script-src.
String generateCspNonce() {
  final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes);
}

/// Returns the Content-Security-Policy header for canvas pages.
///
/// The nonce allows only the page's own inline script to execute,
/// blocking any scripts injected via agent-generated HTML content.
String canvasCspHeader(String nonce) =>
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-$nonce'; "
    "connect-src 'self'; img-src 'self' data:; form-action 'self'; frame-ancestors 'self'";
