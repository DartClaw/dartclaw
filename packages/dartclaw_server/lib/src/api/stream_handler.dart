import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../turn_manager.dart';

String _sseFrame(String event, Map<String, dynamic> data) {
  final encoded = jsonEncode(data);
  // Defensive: jsonEncode escapes \n as \\n in JSON strings, but guard against
  // future code paths that might pass raw strings as data values.
  final safe = encoded.replaceAll('\n', '\\n').replaceAll('\r', '\\r');
  if (encoded != safe) {
    Logger('SSE').warning('Literal newline/carriage-return found in SSE data — sanitized');
  }
  return 'event: $event\ndata: $safe\n\n';
}

Response sseStreamResponse(AgentHarness worker, TurnManager turns, String sessionId, String turnId) {
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

  eventSub = worker.events.listen((event) {
    if (controller.isClosed) return;
    final String frame;
    if (event is DeltaEvent) {
      frame = _sseFrame('delta', {'text': event.text});
    } else if (event is ToolUseEvent) {
      frame = _sseFrame('tool_use', {'tool_name': event.toolName, 'tool_id': event.toolId, 'input': event.input});
    } else if (event is ToolResultEvent) {
      frame = _sseFrame('tool_result', {'tool_id': event.toolId, 'output': event.output, 'is_error': event.isError});
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
        controller.add(utf8.encode(_sseFrame('done', {'turn_id': turnId})));
      } else {
        final message = result.errorMessage ?? 'Turn failed';
        controller.add(
          utf8.encode(
            _sseFrame('error', {'turn_id': turnId, 'status': result.status.name, 'error': message, 'message': message}),
          ),
        );
      }
    } catch (e) {
      if (!controller.isClosed) {
        try {
          controller.add(
            utf8.encode(
              _sseFrame('error', {
                'turn_id': turnId,
                'status': 'failed',
                'error': 'Internal error',
                'message': 'Internal error',
              }),
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
    headers: {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive'},
  );
}
