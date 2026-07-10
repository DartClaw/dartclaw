import 'package:dartclaw_server/src/embedded_static_handler.dart';
import 'package:dartclaw_server/src/version.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final handler = createEmbeddedStaticHandler({
    'static/tokens.css': ':root { --color: blue; }',
    'static/app.js': 'console.log("embedded");',
  });

  test('serves embedded bytes with content and version-keyed cache headers', () async {
    final response = await handler(Request('GET', Uri.parse('http://localhost/tokens.css')));

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], startsWith('text/css'));
    expect(response.headers['cache-control'], contains('public'));
    expect(response.headers['etag'], contains(dartclawVersion));
    expect(await response.readAsString(), ':root { --color: blue; }');
  });

  test('returns 404 for misses and traversal attempts', () async {
    final missing = await handler(Request('GET', Uri.parse('http://localhost/nope.js')));
    final traversal = await handler(Request('GET', Uri.parse('http://localhost/%2E%2E/secrets')));

    expect(missing.statusCode, 404);
    expect(traversal.statusCode, 404);
  });
}
