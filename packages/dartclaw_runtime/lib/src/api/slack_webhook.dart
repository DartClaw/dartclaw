import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart' show SlackEventsHandler;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../auth/auth_utils.dart';

final _log = Logger('SlackWebhook');

/// The Shelf adapter for Slack's signed HTTP deliveries.
///
/// The signature is the route's only gate: it sits outside gateway auth, so
/// nothing reads the body before [handler] verifies it over the exact bytes.
/// A refusal fires the failed-auth event and writes one audit entry through
/// [auditLogger]; an accepted request, a 413 or another webhook writes none.
Handler slackWebhookHandler({
  required SlackEventsHandler handler,
  EventBus? eventBus,
  GuardAuditLogger? auditLogger,
  List<String> trustedProxies = const [],
}) {
  return (Request request) async {
    final body = await readBoundedRequestBytes(request, maxWebhookPayloadBytes);
    if (body == null) {
      _log.warning('Slack webhook payload exceeds size limit');
      return Response(413);
    }

    final response = await handler.handle(body, request.headers);
    final rejection = response.rejection;
    if (rejection != null) {
      final remoteKey = requestRemoteKey(request, trustedProxies: trustedProxies);
      fireFailedAuthEvent(
        eventBus,
        request,
        source: 'webhook',
        reason: rejection.reason,
        trustedProxies: trustedProxies,
      );
      await _audit(auditLogger, rejection.reason, remoteKey);
    }
    return Response(response.statusCode, body: response.body, headers: {'content-type': response.contentType});
  };
}

Future<void> _audit(GuardAuditLogger? auditLogger, String reason, String? remoteKey) async {
  if (auditLogger == null) return;
  try {
    await auditLogger.writeEntry(
      AuditEntry(
        timestamp: DateTime.now(),
        guard: 'slack_signature',
        hook: 'webhook',
        verdict: 'block',
        reason: reason,
        channel: 'slack',
        peerId: remoteKey,
      ),
    );
  } catch (e) {
    _log.warning('Failed to audit a refused Slack request ($reason)', e);
  }
}
