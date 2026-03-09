import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:logging/logging.dart';

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
  })  : _classifier = classifier,
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
          'url': {
            'type': 'string',
            'description': 'URL to fetch',
          },
          'maxLength': {
            'type': 'integer',
            'description':
                'Maximum response length in characters (default: $_defaultMaxLength)',
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
      final ssrfError = _checkSsrfPolicy(uri);
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
        final classification = await classifier.classify(
          result,
          timeout: _timeout,
        );
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
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(_timeout);
        throw HttpException(
          'HTTP ${response.statusCode}: ${response.reasonPhrase} — $body',
        );
      }

      final contentType =
          response.headers.contentType?.mimeType ?? 'text/html';
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);

      return _FetchResult(body: body, contentType: contentType);
    } finally {
      client.close(force: true);
    }
  }

  /// Returns an error message if the URI targets a blocked internal address,
  /// or null if the request is permitted.
  ///
  /// Blocks loopback, link-local, and RFC1918 private ranges to prevent SSRF.
  static String? _checkSsrfPolicy(Uri uri) {
    final host = uri.host.toLowerCase();

    // Block loopback by hostname.
    if (host == 'localhost' || host == '0.0.0.0') {
      return 'Blocked: "$host" is a loopback address';
    }

    // Attempt numeric IP parsing to check private/loopback ranges.
    final parts = host.split('.');
    if (parts.length == 4) {
      final octets = parts.map(int.tryParse).toList();
      if (octets.every((o) => o != null)) {
        final a = octets[0]!;
        final b = octets[1]!;
        // Loopback: 127.x.x.x
        if (a == 127) return 'Blocked: loopback address range ($host)';
        // Link-local: 169.254.x.x
        if (a == 169 && b == 254) return 'Blocked: link-local address range ($host)';
        // RFC1918: 10.x.x.x
        if (a == 10) return 'Blocked: private address range ($host)';
        // RFC1918: 172.16.x.x – 172.31.x.x
        if (a == 172 && b >= 16 && b <= 31) return 'Blocked: private address range ($host)';
        // RFC1918: 192.168.x.x
        if (a == 192 && b == 168) return 'Blocked: private address range ($host)';
      }
    }

    // IPv6 loopback ::1
    if (host == '::1' || host == '[::1]') {
      return 'Blocked: IPv6 loopback address ($host)';
    }

    return null;
  }

  static bool _isHtml(String contentType) =>
      contentType == 'text/html' || contentType == 'application/xhtml+xml';

  static bool _isPlainText(String contentType) =>
      contentType == 'text/plain' ||
      contentType == 'text/markdown' ||
      contentType == 'application/json';
}

class _FetchResult {
  final String body;
  final String contentType;

  _FetchResult({required this.body, required this.contentType});
}
