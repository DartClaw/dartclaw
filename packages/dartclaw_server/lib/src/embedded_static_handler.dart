import 'package:shelf/shelf.dart';

import 'version.dart';

/// Serves static assets compiled into the binary.
Handler createEmbeddedStaticHandler(Map<String, String> assets) {
  return (Request request) {
    final segments = request.url.pathSegments;
    if (request.method != 'GET' || segments.isEmpty || segments.any((segment) => segment == '..' || segment == '.')) {
      return Response.notFound('Not Found');
    }

    final key = 'static/${segments.join('/')}';
    final content = assets[key];
    if (content == null) return Response.notFound('Not Found');

    return Response.ok(
      content,
      headers: {
        'Content-Type': _contentType(key),
        'Cache-Control': 'public, max-age=86400',
        'ETag': '"dartclaw-$dartclawVersion"',
      },
    );
  };
}

String _contentType(String path) => switch (path.split('.').last) {
  'css' => 'text/css; charset=utf-8',
  'js' => 'text/javascript; charset=utf-8',
  'html' => 'text/html; charset=utf-8',
  'svg' => 'image/svg+xml; charset=utf-8',
  _ => 'application/octet-stream',
};
