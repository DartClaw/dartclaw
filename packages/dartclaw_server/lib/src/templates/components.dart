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
///
/// [appName] is the configurable instance name shown in the call-to-action text.
String emptyAppStateTemplate({String appName = 'DartClaw'}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'emptyAppState',
    context: {'appName': appName},
  );
}

/// Status badge with semantic color variant.
///
/// [variant] maps to `status-badge-{variant}` CSS class (e.g., `success`,
/// `error`, `warning`, `muted`, `running`, `queued`).
/// [text] is the badge label, auto-escaped by Trellis.
String statusBadgeTemplate({required String variant, required String text}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'statusBadge',
    context: {'variant': variant, 'text': text},
  );
}

/// Simple metric card with colored accent.
///
/// [color] maps to `card-metric--{color}` CSS class (e.g., `accent`, `info`,
/// `error`, `warning`).
/// Use for KPI displays with a single value and label. For metric cards with
/// custom sub-content (budget bars, fill indicators), use inline HTML instead.
String metricCardTemplate({
  required String color,
  required String value,
  required String label,
}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'metricCard',
    context: {'color': color, 'value': value, 'label': label},
  );
}

/// Info card with header badge and key-value rows.
///
/// [badgeClass] is the badge color class (e.g., `badge-success`, `badge-muted`).
/// [rows] is a list of maps with `label`, `value`, and optional `valueClass` keys.
String infoCardTemplate({
  required String title,
  required String badgeText,
  required String badgeClass,
  required List<Map<String, dynamic>> rows,
}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'infoCard',
    context: {
      'title': title,
      'badgeText': badgeText,
      'badgeClass': badgeClass,
      'rows': rows,
    },
  );
}
