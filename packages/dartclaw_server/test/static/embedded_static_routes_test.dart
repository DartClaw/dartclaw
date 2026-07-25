import 'package:dartclaw_server/src/embedded_static_handler.dart';
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
}
