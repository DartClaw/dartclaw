import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('canvasShareMiddleware', () {
    late CanvasService service;

    setUp(() {
      service = CanvasService();
    });

    tearDown(() async {
      await service.dispose();
    });

    test('valid token passes through and share token is attached to context', () async {
      final token = service.createShareToken('agent:main:web:');
      final handler = canvasShareMiddleware(service)((request) {
        final attached = getShareToken(request);
        expect(attached, isNotNull);
        expect(attached!.token, token.token);
        return Response.ok('ok');
      });

      final response = await handler(Request('GET', Uri.parse('http://localhost/canvas/${token.token}/stream')));
      expect(response.statusCode, 200);
    });

    test('invalid token returns 404', () async {
      final handler = canvasShareMiddleware(service)((_) => Response.ok('ok'));
      final response = await handler(Request('GET', Uri.parse('http://localhost/canvas/not-a-real-token')));
      expect(response.statusCode, 404);
    });

    test('expired token returns 404', () async {
      final token = service.createShareToken('session', ttl: const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final handler = canvasShareMiddleware(service)((_) => Response.ok('ok'));
      final response = await handler(Request('GET', Uri.parse('http://localhost/canvas/${token.token}')));
      expect(response.statusCode, 404);
    });

    test('missing token in path returns 404', () async {
      final handler = canvasShareMiddleware(service)((_) => Response.ok('ok'));
      final response = await handler(Request('GET', Uri.parse('http://localhost/canvas')));
      expect(response.statusCode, 404);
    });
  });
}
