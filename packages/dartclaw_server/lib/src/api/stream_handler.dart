import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

import '../turn_manager.dart';

/// Formats an SSE frame with HTML content. Newlines in [htmlContent] are
/// replaced with spaces because SSE data lines cannot contain literal newlines.
String _sseHtmlFrame(String event, String htmlContent) {
  final safe = htmlContent.replaceAll('\n', ' ').replaceAll('\r', '');
  return 'event: $event\ndata: $safe\n\n';
}

/// Sanitizes a tool ID for use as an HTML element id attribute.
String _sanitizeToolId(String raw) =>
    'tool-${raw.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';

/// Returns an SSE [Response] that streams turn events in real time.
Response sseStreamResponse(
  AgentHarness worker,
  TurnManager turns,
  String sessionId,
  String turnId, {
  MessageRedactor? redactor,
}) {
  // 1. Already completed — no content.
  final outcome = turns.recentOutcome(sessionId, turnId);
  if (outcome != null) return Response(204);

  // 2. Unknown turn — not active and no cached outcome.
  if (!turns.isActiveTurn(sessionId, turnId)) {
    return Response(
      404,
      body: jsonEncode({
        'error': {'code': 'TURN_NOT_FOUND', 'message': 'Turn not found or expired'},
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  // 3. Build SSE stream.
  final controller = StreamController<List<int>>();

  StreamSubscription<BridgeEvent>? eventSub;

  // Cancel event subscription when client disconnects.
  controller.onCancel = () {
    eventSub?.cancel();
  };

  final toolNames = <String, String>{};
  const htmlEscape = HtmlEscape();

  eventSub = worker.events.listen((event) {
    if (controller.isClosed) return;
    final String frame;
    if (event is DeltaEvent) {
      final text = redactor?.redact(event.text) ?? event.text;
      frame = _sseHtmlFrame('delta', '<span>${htmlEscape.convert(text)}</span>');
    } else if (event is ToolUseEvent) {
      final id = _sanitizeToolId(event.toolId);
      final name = htmlEscape.convert(event.toolName);
      toolNames[event.toolId] = event.toolName;
      frame = _sseHtmlFrame(
        'tool_use',
        '<div id="$id" class="tool-indicator pending">$name</div>',
      );
    } else if (event is ToolResultEvent) {
      final id = _sanitizeToolId(event.toolId);
      final name = htmlEscape.convert(toolNames[event.toolId] ?? 'Tool');
      final status = event.isError ? 'error' : 'success';
      frame = _sseHtmlFrame(
        'tool_result',
        '<div id="$id" hx-swap-oob="outerHTML:#$id" class="tool-indicator $status">$name</div>',
      );
    } else {
      return;
    }
    try {
      controller.add(utf8.encode(frame));
    } catch (_) {
      // Controller closed between isClosed check and add — safe to ignore.
    }
  });

  // Await turn completion and emit terminal event, then close stream.
  unawaited(() async {
    try {
      final result = await turns.waitForOutcome(sessionId, turnId);
      if (controller.isClosed) return;
      if (result.status == TurnStatus.completed) {
        controller.add(utf8.encode(_sseHtmlFrame('done', '')));
      } else {
        final message = result.errorMessage ?? 'Turn failed';
        controller.add(
          utf8.encode(
            _sseHtmlFrame(
              'turn_error',
              '<div class="turn-error">${htmlEscape.convert(message)}</div>',
            ),
          ),
        );
      }
    } catch (e) {
      if (!controller.isClosed) {
        try {
          controller.add(
            utf8.encode(
              _sseHtmlFrame(
                'turn_error',
                '<div class="turn-error">Internal error</div>',
              ),
            ),
          );
        } catch (_) {}
      }
    } finally {
      await eventSub?.cancel();
      await controller.close();
    }
  }());

  return Response.ok(
    controller.stream,
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no',
    },
  );
}
