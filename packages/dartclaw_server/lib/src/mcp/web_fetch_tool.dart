import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

/// MCP tool that fetches a URL, converts HTML to markdown, and scans
/// the content through [ContentScan] before returning it to the agent.
///
/// A null [ContentScan] means no classification is configured; the fetched
/// content is then returned under the `maxLength` char truncation alone.
class WebFetchTool implements McpTool {
  static final _log = Logger('WebFetchTool');

  final ContentScan? _scan;
  final Duration _timeout;
  final int _defaultMaxLength;
  final bool _ssrfProtectionEnabled;
  final Future<List<InternetAddress>> Function(String host) _addressLookup;

  new({
    ContentScan? scan,
    Duration timeout = const Duration(seconds: 30),
    int defaultMaxLength = 50000,
    bool ssrfProtectionEnabled = true,
    Future<List<InternetAddress>> Function(String host)? addressLookup,
  }) : _scan = scan,
       _timeout = timeout,
       _defaultMaxLength = defaultMaxLength,
       _ssrfProtectionEnabled = ssrfProtectionEnabled,
       _addressLookup = addressLookup ?? InternetAddress.lookup;

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
        'minimum': 1,
        'maximum': _defaultMaxLength,
        'description':
            'Maximum response length in characters (default: $_defaultMaxLength). '
            'When content classification is configured, the response is additionally capped at '
            'guards.content.max_bytes UTF-8 bytes — everything returned has been scanned.',
      },
    },
    'required': ['url'],
    'additionalProperties': false,
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
      final ssrfError = await _checkSsrfPolicy(uri, _addressLookup);
      if (ssrfError != null) return ToolResult.error(ssrfError);
    }

    final requestedMaxLength = (args['maxLength'] as int?) ?? _defaultMaxLength;
    if (requestedMaxLength < 1 || requestedMaxLength > _defaultMaxLength) {
      return ToolResult.error('maxLength must be between 1 and $_defaultMaxLength');
    }
    final maxLength = requestedMaxLength;

    // 2. Fetch URL via HttpClient.
    String body;
    String contentType;
    try {
      final fetchResult = await _fetch(uri, maxBytes: maxLength * 4);
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

    // 5. Content scan (pre-agent). The scan truncates to its byte cap, so the
    // returned span is exactly what the classifier saw.
    final scan = _scan;
    if (scan == null) return ToolResult.text(result);

    final verdict = await scan.evaluate(result);
    if (verdict.blocked) {
      final classification = verdict.classification;
      return ToolResult.error(
        classification != null
            ? 'Content blocked: classified as $classification'
            : 'Content classification failed — ${verdict.failureReason}',
      );
    }
    return ToolResult.text(verdict.scannedText);
  }

  Future<_FetchResult> _fetch(Uri uri, {required int maxBytes}) async {
    final client = HttpClient();
    client.connectionTimeout = _timeout;
    if (_ssrfProtectionEnabled) {
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = _validatedConnection;
    }
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }

      final contentType = response.headers.contentType?.mimeType ?? 'text/html';
      final body = await _readBounded(response, maxBytes).timeout(_timeout);

      return _FetchResult(body: body, contentType: contentType);
    } finally {
      client.close(force: true);
    }
  }

  Future<ConnectionTask<Socket>> _validatedConnection(Uri uri, String? proxyHost, int? proxyPort) async {
    if (proxyHost != null || proxyPort != null) {
      throw const SocketException('Proxy connections are unavailable for SSRF-protected web fetches');
    }
    final addresses = await _addressLookup(uri.host);
    if (addresses.isEmpty) throw SocketException('DNS resolution returned no addresses for "${uri.host}"');
    for (final address in addresses) {
      final reason = checkResolvedAddress(address);
      if (reason != null) throw SocketException('$reason (resolved from "${uri.host}")');
    }

    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final task = await Socket.startConnect(addresses.first, port);
    if (uri.scheme != 'https') return task;
    final socket = task.socket.then((plain) => SecureSocket.secure(plain, host: uri.host));
    return ConnectionTask.fromSocket(socket, task.cancel);
  }

  static Future<String> _readBounded(HttpClientResponse response, int maxBytes) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      final remaining = maxBytes - bytes.length;
      if (remaining <= 0) break;
      if (chunk.length >= remaining) {
        bytes.add(chunk.sublist(0, remaining));
        break;
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  /// Returns an error message if the URI targets a blocked internal address,
  /// or null if the request is permitted.
  ///
  /// Blocks loopback, link-local, RFC1918 private, CGNAT, multicast/reserved,
  /// and IPv6 private ranges to prevent SSRF. Resolves DNS to catch hostnames
  /// that map to internal addresses.
  static Future<String?> checkSsrfPolicy(Uri uri) async {
    return _checkSsrfPolicy(uri, InternetAddress.lookup);
  }

  static Future<String?> _checkSsrfPolicy(Uri uri, Future<List<InternetAddress>> Function(String host) lookup) async {
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
      addresses = await lookup(host);
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
      if (bytes.every((byte) => byte == 0)) return 'Blocked: IPv6 unspecified address (::)';
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

  new({required this.body, required this.contentType});
}
