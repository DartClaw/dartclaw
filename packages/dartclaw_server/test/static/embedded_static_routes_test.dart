import 'package:dartclaw_server/src/embedded_static_handler.dart';
import 'package:dartclaw_server/src/generated/embedded_assets.g.dart';
import 'package:dartclaw_server/src/version.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final handler = createVersionedStaticHandler(
    createEmbeddedStaticHandler({
      'static/tokens.css': ':root { --color: blue; }',
      'static/app.js': 'console.log("embedded");',
    }, const {}),
  );

  test('serves embedded bytes with revalidation and version-keyed cache headers', () async {
    final response = await handler(Request('GET', Uri.parse('http://localhost/tokens.css')));

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], startsWith('text/css'));
    expect(response.headers['cache-control'], 'no-cache');
    expect(response.headers['etag'], contains(dartclawVersion));
    expect(await response.readAsString(), ':root { --color: blue; }');
  });

  test('returns 404 for misses and traversal attempts', () async {
    final missing = await handler(Request('GET', Uri.parse('http://localhost/nope.js')));
    final traversal = await handler(Request('GET', Uri.parse('http://localhost/%2E%2E/secrets')));

    expect(missing.statusCode, 404);
    expect(traversal.statusCode, 404);
  });

  test('serves the current release asset namespace', () async {
    final response = await handler(Request('GET', Uri.parse('http://localhost/v$dartclawVersion/tokens.css')));

    expect(response.statusCode, 200);
    expect(await response.readAsString(), ':root { --color: blue; }');

    final staleVersion = await handler(Request('GET', Uri.parse('http://localhost/v0.0.0/tokens.css')));
    expect(staleVersion.statusCode, 404);
  });

  test('serves embedded PNG bytes without text encoding', () async {
    const png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a];
    final binaryHandler = createEmbeddedStaticHandler(const {}, {'static/mascot.PNG': png});

    final response = await binaryHandler(Request('GET', Uri.parse('http://localhost/mascot.PNG')));

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'image/png');
    expect(await response.read().expand((chunk) => chunk).toList(), png);
  });

  test('serves embedded WOFF2 bytes as font/woff2 without text encoding', () async {
    // wOF2 signature plus a byte sequence that is not valid UTF-8, so any
    // text round-trip would corrupt the body rather than fail loudly.
    const woff2 = <int>[0x77, 0x4f, 0x46, 0x32, 0x00, 0x01, 0x00, 0x00, 0xff, 0xfe, 0x80, 0xc3];
    final binaryHandler = createEmbeddedStaticHandler(const {}, {'static/fonts/jetbrains-mono-latin.woff2': woff2});

    final response = await binaryHandler(
      Request('GET', Uri.parse('http://localhost/fonts/jetbrains-mono-latin.woff2')),
    );

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'font/woff2');
    expect(await response.read().expand((chunk) => chunk).toList(), woff2);
  });

  test('serves the real vendored WOFF2 subsets byte-identically from the generated bundle', () async {
    final fontHandler = createEmbeddedStaticHandler(embeddedServerAssets, embeddedServerBinaryAssets);

    for (final name in const ['jetbrains-mono-latin.woff2', 'jetbrains-mono-latin-ext.woff2']) {
      final key = 'static/fonts/$name';
      final embedded = embeddedServerBinaryAssets[key];
      expect(embedded, isNotNull, reason: '$key must be embedded as a binary asset, not text');
      expect(embedded!.take(4), const [0x77, 0x4f, 0x46, 0x32], reason: '$name must retain its wOF2 signature');

      final response = await fontHandler(Request('GET', Uri.parse('http://localhost/fonts/$name')));

      expect(response.statusCode, 200, reason: name);
      expect(response.headers['content-type'], 'font/woff2', reason: name);
      expect(await response.read().expand((chunk) => chunk).toList(), embedded, reason: name);
    }
  });

  test('serves vendored scripts same-origin without missing source-map references', () async {
    final scriptHandler = createEmbeddedStaticHandler(embeddedServerAssets, embeddedServerBinaryAssets);

    for (final name in const ['htmx.min.js', 'marked.min.js', 'purify.min.js']) {
      final response = await scriptHandler(Request('GET', Uri.parse('http://localhost/$name')));

      expect(response.statusCode, 200, reason: name);
      expect(response.headers['content-type'], startsWith('text/javascript'), reason: name);
      final body = await response.readAsString();
      expect(body, embeddedServerAssets['static/$name'], reason: name);
      expect(body, isNot(contains('sourceMappingURL=')), reason: '$name must not request an unshipped source map');
    }
  });
}
