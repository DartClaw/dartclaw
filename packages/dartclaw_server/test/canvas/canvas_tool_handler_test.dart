import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/canvas/canvas_tool_handler.dart';
import 'package:dartclaw_server/src/canvas/canvas_service.dart';
import 'package:test/test.dart';

void main() {
  group('CanvasTool', () {
    late CanvasService service;
    late CanvasTool tool;
    const sessionKey = 'agent:main:web:';

    setUp(() {
      service = CanvasService();
      tool = CanvasTool(
        canvasService: service,
        sessionKey: sessionKey,
        baseUrl: 'https://workshop.example.com',
        defaultTtl: const Duration(minutes: 30),
      );
    });

    tearDown(() async {
      await service.dispose();
    });

    test('render action pushes html and returns confirmation', () async {
      final result = await tool.call({'action': 'render', 'html': '<h1>Workshop</h1>'});
      expect(_text(result), 'Canvas updated');
      expect(service.getState(sessionKey)!.currentHtml, '<h1>Workshop</h1>');
    });

    test('clear action clears state and returns confirmation', () async {
      service.push(sessionKey, '<p>hello</p>');
      final result = await tool.call({'action': 'clear'});
      expect(_text(result), 'Canvas cleared');
      expect(service.getState(sessionKey)!.currentHtml, isNull);
    });

    test('share action creates token and returns share URL', () async {
      final result = await tool.call({
        'action': 'share',
        'permission': 'interact',
        'ttl': '30m',
      });

      expect(result, isA<ToolResultText>());
      final text = _text(result);
      expect(text, startsWith('Share URL: https://workshop.example.com/canvas/'));
      expect(service.tokenCount, 1);
    });

    test('present and hide actions toggle visibility', () async {
      final presentResult = await tool.call({'action': 'present'});
      expect(_text(presentResult), 'Canvas visible');
      expect(service.getState(sessionKey)!.visible, isTrue);

      final hideResult = await tool.call({'action': 'hide'});
      expect(_text(hideResult), 'Canvas hidden');
      expect(service.getState(sessionKey)!.visible, isFalse);
    });

    test('unknown action returns error', () async {
      final result = await tool.call({'action': 'unknown'});
      expect(result, isA<ToolResultError>());
      expect(_text(result), contains('Unknown canvas action'));
    });

    test('render without html returns error', () async {
      final result = await tool.call({'action': 'render'});
      expect(result, isA<ToolResultError>());
      expect(_text(result), contains('"html"'));
    });

    test('share without baseUrl configuration returns error', () async {
      final unconfiguredTool = CanvasTool(canvasService: service, sessionKey: sessionKey);
      final result = await unconfiguredTool.call({'action': 'share'});
      expect(result, isA<ToolResultError>());
      expect(_text(result), contains('server.baseUrl'));
    });
  });
}

String _text(ToolResult result) => switch (result) {
  ToolResultText(:final content) => content,
  ToolResultError(:final message) => message,
};
