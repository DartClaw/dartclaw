import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';

import 'alert_classifier.dart';

/// Produces channel-appropriate [ChannelResponse]s for classified alerts.
///
/// - Google Chat (`googlechat`): Cards v2 with severity-colored header via
///   [ChatCardBuilder.alertNotification], plus plain text fallback.
/// - All other channels (WhatsApp, Signal, unknown): plain text only.
///
/// Knows nothing about event types: an alert's body and detail fields arrive
/// already decided from [classifyAlert], so an unclassified event has no route
/// to a channel at all.
///
/// Stateless — safe to share across threads.
class AlertFormatter {
  final ChatCardBuilder _cardBuilder;

  const new({ChatCardBuilder cardBuilder = const ChatCardBuilder()}) : _cardBuilder = cardBuilder;

  /// Formats [classification] into a [ChannelResponse] appropriate for
  /// [channelType].
  ChannelResponse format({required AlertClassification classification, required String channelType}) {
    final title = _title(classification.alertType);
    final severityPrefix = '[${classification.severity.name.toUpperCase()}]';
    final plainText = '$severityPrefix $title: ${classification.body}';

    if (channelType == 'googlechat') {
      final card = _cardBuilder.alertNotification(
        title: title,
        severity: classification.severity.name,
        body: classification.body,
        details: classification.details,
      );
      return ChannelResponse(text: plainText, structuredPayload: card);
    }

    return ChannelResponse(text: plainText);
  }

  /// Formats a burst summary into a [ChannelResponse] appropriate for [channelType].
  ChannelResponse formatSummary({
    required String alertType,
    required AlertSeverity severity,
    required String channelType,
    required int count,
    required Duration cooldown,
  }) {
    final title = '${_title(alertType)} Summary';
    final timeLabel = _timeLabel(cooldown);
    final body = '$count alert${count == 1 ? '' : 's'} in last $timeLabel';
    final severityPrefix = '[${severity.name.toUpperCase()}]';
    final plainText = '$severityPrefix $title: $body';

    if (channelType == 'googlechat') {
      final card = _cardBuilder.alertNotification(
        title: title,
        severity: severity.name,
        body: body,
        details: {'Count': '$count', 'Window': timeLabel},
      );
      return ChannelResponse(text: plainText, structuredPayload: card);
    }

    return ChannelResponse(text: plainText);
  }

  String _title(String alertType) => switch (alertType) {
    'guard_block' => 'Guard Block',
    'container_crash' => 'Container Crash',
    'task_failure' => 'Task Failure',
    'job_failure' => 'Scheduled Job Failure',
    'budget_warning' => 'Budget Warning',
    'compaction' => 'Context Compaction',
    'credential_expiry' => 'Credential Nearing Expiry',
    'credential_refresh_failure' => 'Credential Refresh Failed',
    'credential_reauth_required' => 'Re-authentication Required',
    // A backend auth-scheme change, not an expiry: this wording is the contract
    // that keeps the operator from being sent to a login that cannot help.
    'credential_contract_break' => 'Mediation Contract Broken',
    'emergency_stop' => 'Emergency Stop',
    'loop_detected' => 'Loop Detected',
    _ => alertType,
  };

  static String _timeLabel(Duration cooldown) {
    final minutes = cooldown.inMinutes;
    if (minutes > 0 && cooldown.inSeconds % 60 == 0) {
      return '$minutes minute${minutes == 1 ? '' : 's'}';
    }
    return '${cooldown.inSeconds} seconds';
  }
}
