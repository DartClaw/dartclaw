import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'signal_pairing.dart';
import 'web_routes.dart' show buildSidebarData;

const _htmlHeaders = {'content-type': 'text/html; charset=utf-8'};

/// Signal pairing page and registration routes.
///
/// Extracted from [DartclawServer.handler] so they can be tested
/// independently without constructing the full server.
Router signalPairingRoutes({
  required SignalChannel signalChannel,
  required SessionService sessions,
}) {
  final router = Router();

  // GET /pairing — Signal pairing/status page.
  router.get('/pairing', (Request request) async {
    final sidebarData = await buildSidebarData(sessions);
    final phone = signalChannel.config.phoneNumber;
    final error = request.requestedUri.queryParameters['error'];
    final step = request.requestedUri.queryParameters['step'];

    var verificationPending = false;
    var isConnected = false;
    String? connectedPhone;
    String? configuredPhone = phone;
    String? linkDeviceUri;
    String? templateError = error;

    if (step == 'verify') {
      verificationPending = true;
    } else {
      try {
        final reachable = await signalChannel.sidecar.healthCheck();
        if (reachable) {
          final registered = await signalChannel.sidecar.isAccountRegistered();
          if (registered) {
            isConnected = true;
            connectedPhone = phone;
            configuredPhone = null;
            templateError = null;
          } else {
            linkDeviceUri = await signalChannel.sidecar.getLinkDeviceUri();
          }
        }
      } catch (e) {
        templateError = 'Failed to check signal-cli status: $e';
      }
    }

    return Response.ok(
      signalPairingTemplate(
        verificationPending: verificationPending,
        isConnected: isConnected,
        connectedPhone: connectedPhone,
        configuredPhone: configuredPhone,
        linkDeviceUri: linkDeviceUri,
        error: templateError,
        sidebarData: sidebarData,
        signalEnabled: true,
      ),
      headers: _htmlHeaders,
    );
  });

  // POST /pairing/register — trigger SMS verification.
  router.post('/pairing/register', (Request request) async {
    try {
      await signalChannel.sidecar.requestSmsVerification();
      return Response.found('/signal/pairing?step=verify');
    } catch (e) {
      final msg = Uri.encodeQueryComponent('Failed to send SMS: $e');
      return Response.found('/signal/pairing?error=$msg');
    }
  });

  // POST /pairing/register-voice — trigger voice call verification.
  router.post('/pairing/register-voice', (Request request) async {
    try {
      await signalChannel.sidecar.requestVoiceVerification();
      return Response.found('/signal/pairing?step=verify');
    } catch (e) {
      final msg = Uri.encodeQueryComponent('Failed to request voice call: $e');
      return Response.found('/signal/pairing?error=$msg');
    }
  });

  // POST /pairing/verify — complete SMS/voice verification.
  router.post('/pairing/verify', (Request request) async {
    try {
      final body = await request.readAsString();
      final params = Uri.splitQueryString(body);
      final token = params['token'] ?? '';
      if (token.isEmpty) {
        return Response.found('/signal/pairing?step=verify&error=${Uri.encodeQueryComponent('Code is required')}');
      }
      await signalChannel.sidecar.verifySmsCode(token);
      return Response.found('/signal/pairing');
    } catch (e) {
      final msg = Uri.encodeQueryComponent('Verification failed: $e');
      return Response.found('/signal/pairing?step=verify&error=$msg');
    }
  });

  return router;
}
