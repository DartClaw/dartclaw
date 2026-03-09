import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/web_fetch_tool.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class _FakeClassifier implements ContentClassifier {
  String result;
  bool shouldThrow;

  _FakeClassifier({this.result = 'safe', this.shouldThrow = false});

  @override
  Future<String> classify(String content, {Duration timeout = const Duration(seconds: 15)}) async {
    if (shouldThrow) throw Exception('classification unavailable');
    return result;
  }
}

// ---------------------------------------------------------------------------
// Test HTTP server helpers
// ---------------------------------------------------------------------------

Future<HttpServer> _startServer(
  Future<void> Function(HttpRequest) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

String _serverUrl(HttpServer server, [String path = '/']) =>
    'http://127.0.0.1:${server.port}$path';

/// Extracts the text content from a [ToolResult].
String _text(ToolResult result) => switch (result) {
      ToolResultText(:final content) => content,
      ToolResultError(:final message) => message,
    };

/// Creates a [WebFetchTool] with SSRF protection disabled for local test servers.
WebFetchTool _noSsrfTool({
  ContentClassifier? classifier,
  Duration? timeout,
  int? defaultMaxLength,
  bool failOpenOnClassification = true,
}) =>
    WebFetchTool(
      classifier: classifier,
      timeout: timeout ?? const Duration(seconds: 30),
      defaultMaxLength: defaultMaxLength ?? 50000,
      failOpenOnClassification: failOpenOnClassification,
      ssrfProtectionEnabled: false,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WebFetchTool', () {
    group('MCP interface', () {
      test('name is web_fetch', () {
        final tool = WebFetchTool();
        expect(tool.name, 'web_fetch');
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
            ..write('Not Found');
          await req.response.close();
        });

        final tool = _noSsrfTool();
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('404'));
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
        final classifier = _FakeClassifier(result: 'safe');
        final tool = _noSsrfTool(classifier: classifier);
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('Some content'));
      });

      test('blocked content returns error result', () async {
        final classifier = _FakeClassifier(result: 'prompt_injection');
        final tool = _noSsrfTool(classifier: classifier);
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultError>());
        expect(_text(result), contains('Content blocked'));
        expect(_text(result), contains('prompt_injection'));
      });

      test('classifier error with failOpen=true returns content', () async {
        final classifier = _FakeClassifier(shouldThrow: true);
        final tool = _noSsrfTool(
          classifier: classifier,
          failOpenOnClassification: true,
        );
        final result = await tool.call({'url': _serverUrl(server)});
        expect(result, isA<ToolResultText>());
        expect(_text(result), contains('Some content'));
      });

      test('classifier error with failOpen=false returns error', () async {
        final classifier = _FakeClassifier(shouldThrow: true);
        final tool = _noSsrfTool(
          classifier: classifier,
          failOpenOnClassification: false,
        );
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
        final result = await tool.call({
          'url': _serverUrl(server),
          'maxLength': 100,
        });
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
