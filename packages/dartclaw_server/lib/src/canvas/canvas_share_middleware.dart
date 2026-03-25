import 'package:shelf/shelf.dart';

import 'canvas_service.dart';
import 'canvas_state.dart';

const canvasShareTokenContextKey = 'dartclaw.canvas.shareToken';

Middleware canvasShareMiddleware(CanvasService canvasService) {
  return (Handler inner) => (Request request) async {
    final token = _extractTokenFromPath(request.url.pathSegments);
    if (token == null) {
      return Response.notFound('Not found');
    }

    final shareToken = canvasService.validateShareToken(token);
    if (shareToken == null) {
      return Response.notFound('Not found');
    }

    final nextRequest = request.change(context: {...request.context, canvasShareTokenContextKey: shareToken});
    return inner(nextRequest);
  };
}

CanvasShareToken? getShareToken(Request request) {
  return request.context[canvasShareTokenContextKey] as CanvasShareToken?;
}

String? _extractTokenFromPath(List<String> segments) {
  if (segments.isEmpty) return null;
  // When mounted under /canvas, shelf strips the mount prefix so the token
  // is the first segment. When the router preserves the prefix, it's second.
  if (segments.first == 'canvas') {
    return segments.length > 1 ? segments[1] : null;
  }
  return segments.first;
}
