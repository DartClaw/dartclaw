import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/web_fetch_tool.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeContentClassifier;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test HTTP server helpers
// ---------------------------------------------------------------------------

Future<HttpServer> _startServer(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

String _serverUrl(HttpServer server, [String path = '/']) => 'http://127.0.0.1:${server.port}$path';

/// Extracts the text content from a [ToolResult].
String _text(ToolResult result) => switch (result) {
  ToolResultText(:final content) => content,
  ToolResultError(:final message) => message,
};

/// Creates a [WebFetchTool] with SSRF protection disabled for local test servers.
WebFetchTool _noSsrfTool({ContentScan? scan, Duration? timeout, int? defaultMaxLength}) => WebFetchTool(
  scan: scan,
  timeout: timeout ?? const Duration(seconds: 30),
  defaultMaxLength: defaultMaxLength ?? 50000,
  ssrfProtectionEnabled: false,
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WebFetchTool', () {
    group('MCP interface', () {
      test('name is web_fetch — wire contract', () {
        // NetworkGuard branches on this exact literal (`network_guard.dart` `toolName == 'web_fetch'`)
        // and ADR-009 pins it in `disallowedTools`; a rename must fail here.
        expect(WebFetchTool().name, 'web_fetch');
      });

      test('inputSchema has correct structure', () {
        final tool = WebFetchTool();
        expect(tool.inputSchema['type'], 'object');
        final required = tool.inputSchema['required'] as List;
        expect(required, contains('url'));
        final props = tool.inputSchema['properties'] as Map<String, dynamic>;
        expect(props.containsKey('url'), isTrue);
        expect(props.containsKey('maxLength'), isTrue);
      });

      test('description is non-empty', () {
        final tool = WebFetchTool();
        expect(tool.description, isNotEmpty);
      });
    });

    group('SSRF protection', () {
      test('loopback address is blocked', () async {
        final tool = WebFetchTool();
        final result = await tool.call({'url': 'http://127.0.0.1/secret'});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Blocked'));
      });

      test('localhost is blocked', () async {
        final tool = WebFetchTool();
        final result = await tool.call({'url': 'http://localhost/secret'});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Blocked'));
      });

      test('RFC1918 private range 192.168.x.x is blocked', () async {
        final tool = WebFetchTool();
        final result = await tool.call({'url': 'http://192.168.1.1/admin'});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Blocked'));
      });

      test('non-http scheme is blocked', () async {
        final tool = WebFetchTool();
        final result = await tool.call({'url': 'ftp://example.com/file'});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('ftp'));
      });

      test('SSRF disabled allows loopback', () async {
        // Verify the flag works (connection refused expected, not SSRF block).
        final tool = _noSsrfTool(timeout: const Duration(seconds: 1));
        final result = await tool.call({'url': 'http://127.0.0.1:1/test'});
        expect(result, isA<ToolResultError>());
        // Should fail with connection error, NOT with 'Blocked'.
        expect(_text(result), isNot(contains('Blocked')));
      });

      test('DNS resolution catches localhost-resolving hostname', () async {
        // localhost resolves to 127.0.0.1 via DNS — should be caught
        // even though "localhost" is already caught by the fast path,
        // this validates the async checkSsrfPolicy flow end-to-end.
        final result = await WebFetchTool.checkSsrfPolicy(Uri.parse('http://localhost/secret'));
        expect(result, isNotNull);
        expect(result, contains('Blocked'));
      });

      test('connection-time DNS is rechecked before a socket is opened', () async {
        var lookups = 0;
        final tool = WebFetchTool(
          addressLookup: (_) async {
            lookups++;
            return [InternetAddress(lookups == 1 ? '8.8.8.8' : '127.0.0.1')];
          },
        );

        final result = await tool.call({'url': 'http://rebind.test/'});

        expect(result, isA<ToolResultError>());
        expect(lookups, 2);
        expect(_text(result), contains('Blocked'));
      });
    });

    group('checkIpv4Octets', () {
      test('blocks loopback 127.x.x.x', () {
        expect(WebFetchTool.checkIpv4Octets(127, 0), contains('loopback'));
        expect(WebFetchTool.checkIpv4Octets(127, 1), contains('loopback'));
      });

      test('blocks link-local 169.254.x.x', () {
        expect(WebFetchTool.checkIpv4Octets(169, 254), contains('link-local'));
      });

      test('blocks RFC1918 10.x.x.x', () {
        expect(WebFetchTool.checkIpv4Octets(10, 0), contains('RFC1918'));
        expect(WebFetchTool.checkIpv4Octets(10, 255), contains('RFC1918'));
      });

      test('blocks RFC1918 172.16-31.x.x', () {
        expect(WebFetchTool.checkIpv4Octets(172, 16), contains('RFC1918'));
        expect(WebFetchTool.checkIpv4Octets(172, 31), contains('RFC1918'));
        // 172.15 and 172.32 should NOT be blocked.
        expect(WebFetchTool.checkIpv4Octets(172, 15), isNull);
        expect(WebFetchTool.checkIpv4Octets(172, 32), isNull);
      });

      test('blocks RFC1918 192.168.x.x', () {
        expect(WebFetchTool.checkIpv4Octets(192, 168), contains('RFC1918'));
      });

      test('blocks CGNAT 100.64-127.x.x', () {
        expect(WebFetchTool.checkIpv4Octets(100, 64), contains('CGNAT'));
        expect(WebFetchTool.checkIpv4Octets(100, 127), contains('CGNAT'));
        // 100.63 and 100.128 should NOT be blocked.
        expect(WebFetchTool.checkIpv4Octets(100, 63), isNull);
        expect(WebFetchTool.checkIpv4Octets(100, 128), isNull);
      });

      test('blocks unspecified 0.x.x.x', () {
        expect(WebFetchTool.checkIpv4Octets(0, 0), contains('unspecified'));
      });

      test('blocks multicast/reserved >= 224', () {
        expect(WebFetchTool.checkIpv4Octets(224, 0), contains('multicast'));
        expect(WebFetchTool.checkIpv4Octets(255, 255), contains('multicast'));
      });

      test('allows public addresses', () {
        expect(WebFetchTool.checkIpv4Octets(8, 8), isNull);
        expect(WebFetchTool.checkIpv4Octets(93, 184), isNull);
        expect(WebFetchTool.checkIpv4Octets(203, 0), isNull);
      });
    });

    group('checkResolvedAddress', () {
      test('blocks IPv4 loopback', () {
        final addr = InternetAddress('127.0.0.1');
        expect(WebFetchTool.checkResolvedAddress(addr), contains('loopback'));
      });

      test('blocks IPv6 loopback', () {
        final addr = InternetAddress('::1');
        expect(WebFetchTool.checkResolvedAddress(addr), contains('loopback'));
      });

      test('blocks IPv6 unspecified', () {
        expect(WebFetchTool.checkResolvedAddress(InternetAddress('::')), contains('unspecified'));
      });

      test('blocks RFC1918 via resolved address', () {
        final addr = InternetAddress('10.0.0.1');
        expect(WebFetchTool.checkResolvedAddress(addr), contains('Blocked'));
      });

      test('blocks 192.168 via resolved address', () {
        final addr = InternetAddress('192.168.1.1');
        expect(WebFetchTool.checkResolvedAddress(addr), contains('Blocked'));
      });

      test('allows public IPv4', () {
        final addr = InternetAddress('8.8.8.8');
        expect(WebFetchTool.checkResolvedAddress(addr), isNull);
      });
    });

    group('input validation', () {
      test('missing url returns error result', () async {
        final tool = WebFetchTool();
        final result = await tool.call({});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('url'));
      });

      test('empty url returns error result', () async {
        final tool = WebFetchTool();
        final result = await tool.call({'url': ''});
        expect(result, isA<ToolResultError>());
      });

      test('invalid url returns error result', () async {
        final tool = WebFetchTool();
        final result = await tool.call({'url': 'not a valid url'});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Invalid URL'));
      });
    });

    group('HTTP fetching', () {
      late HttpServer server;

      tearDown(() async {
        await server.close(force: true);
      });

      test('HTML content returns markdown conversion', () async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.html
            ..write('<h1>Hello</h1><p>World</p>');
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('Hello'));
        expect(_text(result), contains('World'));
      });

      test('plain text content returns raw text', () async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.text
            ..write('Just plain text');
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), 'Just plain text');
      });

      test('JSON content returns raw JSON', () async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'key': 'value'}));
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('"key"'));
        expect(_text(result), contains('"value"'));
      });

      test('non-2xx status returns error with status code', () async {
        server = await _startServer((req) async {
          req.response
            ..statusCode = 404
            ..write('UNTRUSTED-ERROR-BODY');
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('404'));
        expect(_text(result), isNot(contains('UNTRUSTED-ERROR-BODY')));
      });

      test('redirects are not followed', () async {
        server = await _startServer((req) async {
          req.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:1/internal')
            ..write('redirect body');
          await req.response.close();
        });

        final result = await _noSsrfTool().call({'url': _serverUrl(server)});

        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('302'));
        expect(_text(result), isNot(contains('redirect body')));
      });

      test('response buffering stops at the configured bound', () async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.text
            ..write('x' * 100000);
          await req.response.close();
        });

        final result = await _noSsrfTool(defaultMaxLength: 100).call({'url': _serverUrl(server)});

        expect(result, isA<ToolResultText>());
        expect(_text(result), hasLength(100));
      });

      test('connection refused returns descriptive error', () async {
        // Use a port that's not listening.
        final tool = _noSsrfTool(timeout: const Duration(seconds: 2));
        final result = await tool.call({'url': 'http://127.0.0.1:1'});
        expect(result, isA<ToolResultError>());
      });

      test('unsupported content type returns error', () async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.binary
            ..write('binary data');
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Unsupported content type'));
      });
    });

    group('HTML-to-markdown conversion', () {
      late HttpServer server;

      tearDown(() async {
        await server.close(force: true);
      });

      test('basic HTML converts correctly', () async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.html
            ..write('<h1>Title</h1><p>Paragraph with <a href="https://example.com">link</a></p>');
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('Title'));
        expect(_text(result), contains('link'));
      });
    });

    group('ContentClassifier integration', () {
      late HttpServer server;

      setUp(() async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.html
            ..write('<p>Some content</p>');
          await req.response.close();
        });
      });

      tearDown(() async {
        await server.close(force: true);
      });

      test('safe content returns text result', () async {
        final classifier = FakeContentClassifier(result: 'safe');
        final tool = _noSsrfTool(scan: ContentScan(classifier: classifier));
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('Some content'));
      });

      test('blocked content returns error result', () async {
        final classifier = FakeContentClassifier(result: 'prompt_injection');
        final tool = _noSsrfTool(scan: ContentScan(classifier: classifier));
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Content blocked'));
        expect(_text(result), contains('prompt_injection'));
      });

      test('classifier error with failOpen=true returns content', () async {
        final classifier = FakeContentClassifier(shouldThrow: true);
        final tool = _noSsrfTool(scan: ContentScan(classifier: classifier, failOpen: true));
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('Some content'));
      });

      test('classifier error with failOpen=false returns error', () async {
        final classifier = FakeContentClassifier(shouldThrow: true);
        final tool = _noSsrfTool(scan: ContentScan(classifier: classifier));
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('classification failed'));
      });

      test('no classifier (null) passes content through', () async {
        final tool = _noSsrfTool(); // No classifier.
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('Some content'));
      });

      // A construction that bypasses wiring gets ContentScan's fail-closed
      // default — WebFetchTool no longer carries a fail policy of its own.
      test('a scan constructed without an explicit fail policy fails closed', () async {
        final tool = _noSsrfTool(scan: ContentScan(classifier: FakeContentClassifier(shouldThrow: true)));
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Content classification failed'));
      });

      // Behavior change: the classify timeout is the scan's 15s, not the tool's
      // 30s HTTP timeout, which it used to pass through.
      test('classification uses the scan timeout, not the HTTP timeout', () async {
        final classifier = FakeContentClassifier(result: 'safe');
        final tool = _noSsrfTool(
          scan: ContentScan(classifier: classifier),
          timeout: const Duration(seconds: 30),
        );
        await tool.call({'url': _serverUrl(server)});
        expect(classifier.lastTimeout, const Duration(seconds: 15));
      });
    });

    group('content scan span', () {
      late HttpServer server;

      tearDown(() async {
        await server.close(force: true);
      });

      // The tool returns exactly the span the classifier saw, so no unscanned
      // byte reaches the agent.
      test('returned body is byte-identical to the scanned span and within the byte cap', () async {
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.text
            ..write('A' * 500);
          await req.response.close();
        });

        final classifier = FakeContentClassifier(result: 'safe');
        final tool = _noSsrfTool(scan: ContentScan(classifier: classifier, maxContentBytes: 100));
        final result = await tool.call({'url': _serverUrl(server), 'maxLength': 400});
        expect(result, isA<ToolResultText>());
        expect(_text(result), classifier.lastContent);
        expect(utf8.encode(_text(result)).length, lessThanOrEqualTo(100));
      });

      // Intended, not user-visible: an empty body has nothing to score.
      test('an empty body reaches no classifier', () async {
        server = await _startServer((req) async {
          req.response.headers.contentType = ContentType.text;
          await req.response.close();
        });

        final classifier = FakeContentClassifier(result: 'safe');
        final tool = _noSsrfTool(scan: ContentScan(classifier: classifier));
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(classifier.callCount, 0);
      });
    });

    group('truncation', () {
      late HttpServer server;

      tearDown(() async {
        await server.close(force: true);
      });

      test('response exceeding maxLength is truncated', () async {
        final longContent = 'A' * 500;
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.text
            ..write(longContent);
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server), 'maxLength': 100});
        expect(result, isA<ToolResultText>());
        expect(_text(result).length, 100);
      });

      test('default maxLength (50000) applied', () async {
        // Just verify it doesn't crash with a normal-length response.
        server = await _startServer((req) async {
          req.response
            ..headers.contentType = ContentType.text
            ..write('Short content');
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), 'Short content');
      });
    });
  });
}
