import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('canvasAdminRoutes', () {
    late CanvasService canvasService;
    late Handler handler;

    setUpAll(() {
      initTemplates('packages/dartclaw_server/lib/src/templates');
    });

    setUp(() {
      canvasService = CanvasService();
      handler = canvasAdminRoutes(canvasService: canvasService).call;
    });

    tearDown(() async {
      await canvasService.dispose();
    });

    tearDownAll(() {
      resetTemplates();
    });

    test('POST creates share token and returns URL + QR SVG', () async {
      final response = await handler(
        Request(
          'POST',
          Uri.parse('https://workshop.example.com/api/canvas/share'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'sessionKey': SessionKey.webSession(),
            'permission': 'interact',
            'label': 'Workshop',
          }),
        ),
      );

      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(response.statusCode, 200);
      expect(body['url'], contains('https://workshop.example.com/canvas/'));
      expect(body['permission'], 'interact');
      expect(body['qrSvg'], contains('<svg'));
    });

    test('GET lists active tokens for a session', () async {
      canvasService.createShareToken(SessionKey.webSession(), label: 'One');

      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/canvas/share?sessionKey=${Uri.encodeQueryComponent(SessionKey.webSession())}')),
      );

      final body = jsonDecode(await response.readAsString()) as List<dynamic>;
      expect(response.statusCode, 200);
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['label'], 'One');
    });

    test('DELETE revokes share token', () async {
      final token = canvasService.createShareToken(SessionKey.webSession());

      final response = await handler(Request('DELETE', Uri.parse('http://localhost/api/canvas/share/${token.token}')));

      expect(response.statusCode, 200);
      expect(canvasService.validateShareToken(token.token), isNull);
    });

    test('embed page renders lightweight HTML document', () async {
      final key = SessionKey.webSession();
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions/${Uri.encodeComponent(key)}/canvas/embed')),
      );
      final body = await response.readAsString();

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'text/html; charset=utf-8');
      expect(body, contains('data-stream-url="/api/sessions/${Uri.encodeComponent(key)}/canvas/embed/stream"'));
      expect(body, contains('id="canvas-content"'));
    });
  });
}
