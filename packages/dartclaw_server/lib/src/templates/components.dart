import 'loader.dart';

/// Banner notification. [type] is one of `error`, `warning`, or `info`.
/// [message] is auto-escaped by Trellis (`tl:text`).
String bannerTemplate(String type, String message) {
  final safeType = const {'error', 'warning', 'info'}.contains(type) ? type : 'error';
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'banner',
    context: {'type': safeType, 'message': message},
  );
}

/// Empty state shown when a session has no messages yet.
String emptyStateTemplate() {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'emptyState',
    context: const {},
  );
}

/// Empty app state shown when no sessions exist yet.
String emptyAppStateTemplate() {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'emptyAppState',
    context: const {},
  );
}
