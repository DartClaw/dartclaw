import 'package:shelf/shelf.dart';

import 'version.dart';

/// Routes the current release's versioned static namespace to [handler].
///
/// Unversioned paths remain available for compatibility. A different version
/// stays a miss so browsers cannot combine assets from two releases.
Handler createVersionedStaticHandler(Handler handler) {
  return (Request request) {
    final segments = request.url.pathSegments;
    final versionSegment = 'v$dartclawVersion';
    if (segments.isNotEmpty && segments.first == versionSegment) {
      return handler(request.change(path: versionSegment));
    }
    return handler(request);
  };
}

/// Serves static assets compiled into the binary.
Handler createEmbeddedStaticHandler(Map<String, String> assets, Map<String, List<int>> binaryAssets) {
  return (Request request) {
    final segments = request.url.pathSegments;
    if (request.method != 'GET' || segments.isEmpty || segments.any((segment) => segment == '..' || segment == '.')) {
      return Response.notFound('Not Found');
    }

    final key = 'static/${segments.join('/')}';
    final binaryContent = binaryAssets[key];
    if (binaryContent != null) {
      return Response.ok(
        binaryContent,
        headers: {
          'Content-Type': _contentType(key),
          'Cache-Control': 'no-cache',
          'ETag': '"dartclaw-$dartclawVersion"',
        },
      );
    }
    final content = assets[key];
    if (content == null) return Response.notFound('Not Found');

    return Response.ok(
      content,
      headers: {'Content-Type': _contentType(key), 'Cache-Control': 'no-cache', 'ETag': '"dartclaw-$dartclawVersion"'},
    );
  };
}

String _contentType(String path) => switch (path.split('.').last.toLowerCase()) {
  'css' => 'text/css; charset=utf-8',
  'js' => 'text/javascript; charset=utf-8',
  'html' => 'text/html; charset=utf-8',
  'svg' => 'image/svg+xml; charset=utf-8',
  'png' => 'image/png',
  _ => 'application/octet-stream',
};
