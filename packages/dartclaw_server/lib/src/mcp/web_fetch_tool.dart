import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

/// MCP tool that fetches a URL, converts HTML to markdown, and scans
/// the content through [ContentClassifier] before returning it to the agent.
class WebFetchTool implements McpTool {
  static final _log = Logger('WebFetchTool');

  final ContentClassifier? _classifier;
  final Duration _timeout;
  final int _defaultMaxLength;
  final bool _failOpenOnClassification;
  final bool _ssrfProtectionEnabled;

  WebFetchTool({
    ContentClassifier? classifier,
    Duration timeout = const Duration(seconds: 30),
    int defaultMaxLength = 50000,
    bool failOpenOnClassification = true,
    bool ssrfProtectionEnabled = true,
  }) : _classifier = classifier,
       _timeout = timeout,
       _defaultMaxLength = defaultMaxLength,
       _failOpenOnClassification = failOpenOnClassification,
       _ssrfProtectionEnabled = ssrfProtectionEnabled;

  @override
  String get name => 'web_fetch';

  @override
  String get description =>
      'Fetch a URL and return its content as markdown. '
      'Content is scanned for safety before returning.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'URL to fetch'},
      'maxLength': {
        'type': 'integer',
        'description': 'Maximum response length in characters (default: $_defaultMaxLength)',
      },
    },
    'required': ['url'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    // 1. Extract and validate URL.
    final rawUrl = args['url'] as String?;
    if (rawUrl == null || rawUrl.isEmpty) {
      return ToolResult.error('Missing required parameter "url"');
    }

    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return ToolResult.error('Invalid URL "$rawUrl"');
    }

    // SSRF protection: allow only http/https and block private/internal targets.
    if (_ssrfProtectionEnabled) {
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return ToolResult.error('Unsupported URL scheme "${uri.scheme}" — only http/https allowed');
      }
      final ssrfError = await checkSsrfPolicy(uri);
      if (ssrfError != null) return ToolResult.error(ssrfError);
    }

    final maxLength = (args['maxLength'] as int?) ?? _defaultMaxLength;

    // 2. Fetch URL via HttpClient.
    String body;
    String contentType;
    try {
      final fetchResult = await _fetch(uri);
      body = fetchResult.body;
      contentType = fetchResult.contentType;
    } on TimeoutException {
      return ToolResult.error('Request timed out after ${_timeout.inSeconds}s');
    } on SocketException catch (e) {
      return ToolResult.error('Connection failed — ${e.message}');
    } on HttpException catch (e) {
      return ToolResult.error('HTTP error — ${e.message}');
    } catch (e) {
      return ToolResult.error('Failed to fetch URL — $e');
    }

    // 3. Convert based on content type.
    String result;
    if (_isHtml(contentType)) {
      try {
        result = html2md.convert(body);
      } catch (e) {
        _log.warning('HTML-to-markdown conversion failed: $e');
        result = body; // Fall back to raw HTML.
      }
    } else if (_isPlainText(contentType)) {
      result = body;
    } else {
      return ToolResult.error('Unsupported content type: $contentType');
    }

    // 4. Truncate.
    if (result.length > maxLength) {
      result = result.substring(0, maxLength);
    }

    // 5. ContentClassifier scan (pre-agent).
    final classifier = _classifier;
    if (classifier != null) {
      try {
        final classification = await classifier.classify(result, timeout: _timeout);
        if (classification != 'safe') {
          return ToolResult.error('Content blocked: classified as $classification');
        }
      } catch (e) {
        _log.warning('Content classification failed: $e');
        if (!_failOpenOnClassification) {
          return ToolResult.error('Content classification failed — $e');
        }
        // failOpen: return content despite classification failure.
      }
    }

    return ToolResult.text(result);
  }

  Future<_FetchResult> _fetch(Uri uri) async {
    final client = HttpClient();
    client.connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.transform(utf8.decoder).join().timeout(_timeout);
        throw HttpException('HTTP ${response.statusCode}: ${response.reasonPhrase} — $body');
      }

      final contentType = response.headers.contentType?.mimeType ?? 'text/html';
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);

      return _FetchResult(body: body, contentType: contentType);
    } finally {
      client.close(force: true);
    }
  }

  /// Returns an error message if the URI targets a blocked internal address,
  /// or null if the request is permitted.
  ///
  /// Blocks loopback, link-local, RFC1918 private, CGNAT, multicast/reserved,
  /// and IPv6 private ranges to prevent SSRF. Resolves DNS to catch hostnames
  /// that map to internal addresses.
  @visibleForTesting
  static Future<String?> checkSsrfPolicy(Uri uri) async {
    final host = uri.host.toLowerCase();

    // Fast path: literal hostname checks.
    if (host == 'localhost' || host == '0.0.0.0') {
      return 'Blocked: "$host" is a loopback address';
    }
    if (host == '::1' || host == '[::1]') {
      return 'Blocked: IPv6 loopback address ($host)';
    }

    // Fast path: literal IPv4 checks.
    final parts = host.split('.');
    if (parts.length == 4) {
      final octets = parts.map(int.tryParse).toList();
      if (octets.every((o) => o != null)) {
        final reason = checkIpv4Octets(octets[0]!, octets[1]!);
        if (reason != null) return reason;
      }
    }

    // Resolve DNS and check all resolved addresses.
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } on SocketException {
      return 'DNS resolution failed for "$host"';
    }

    if (addresses.isEmpty) {
      return 'DNS resolution returned no addresses for "$host"';
    }

    for (final addr in addresses) {
      final reason = checkResolvedAddress(addr);
      if (reason != null) return '$reason (resolved from "$host")';
    }

    return null;
  }

  /// Checks an IPv4 address (by first two octets) for private/internal ranges.
  @visibleForTesting
  static String? checkIpv4Octets(int a, int b) {
    if (a == 127) return 'Blocked: loopback address range';
    if (a == 169 && b == 254) return 'Blocked: link-local address range';
    if (a == 10) return 'Blocked: private address range (RFC1918)';
    if (a == 172 && b >= 16 && b <= 31) {
      return 'Blocked: private address range (RFC1918)';
    }
    if (a == 192 && b == 168) return 'Blocked: private address range (RFC1918)';
    if (a == 100 && b >= 64 && b <= 127) {
      return 'Blocked: CGNAT address range (RFC6598)';
    }
    if (a == 0) return 'Blocked: unspecified address range';
    if (a >= 224) return 'Blocked: multicast/reserved address range';
    return null;
  }

  /// Checks a resolved [InternetAddress] against all private/internal ranges.
  @visibleForTesting
  static String? checkResolvedAddress(InternetAddress addr) {
    if (addr.isLoopback) return 'Blocked: loopback address (${addr.address})';
    if (addr.isLinkLocal) {
      return 'Blocked: link-local address (${addr.address})';
    }

    if (addr.type == InternetAddressType.IPv4) {
      final bytes = addr.rawAddress;
      return checkIpv4Octets(bytes[0], bytes[1]);
    }

    if (addr.type == InternetAddressType.IPv6) {
      final bytes = addr.rawAddress;
      // fc00::/7 — Unique Local Address
      if ((bytes[0] & 0xFE) == 0xFC) {
        return 'Blocked: IPv6 ULA (${addr.address})';
      }
      // ::ffff:0:0/96 — IPv4-mapped IPv6
      final isV4Mapped = bytes.sublist(0, 10).every((b) => b == 0) && bytes[10] == 0xFF && bytes[11] == 0xFF;
      if (isV4Mapped) {
        return checkIpv4Octets(bytes[12], bytes[13]);
      }
    }

    return null;
  }

  static bool _isHtml(String contentType) => contentType == 'text/html' || contentType == 'application/xhtml+xml';

  static bool _isPlainText(String contentType) =>
      contentType == 'text/plain' || contentType == 'text/markdown' || contentType == 'application/json';
}

class _FetchResult {
  final String body;
  final String contentType;

  _FetchResult({required this.body, required this.contentType});
}
