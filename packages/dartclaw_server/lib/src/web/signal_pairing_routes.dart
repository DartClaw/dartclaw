import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'page_registry.dart';
import 'signal_pairing.dart';
import 'web_routes.dart' show buildSidebarData;
import 'web_utils.dart';

/// Signal pairing page and registration routes.
///
/// Extracted from [DartclawServer.handler] so they can be tested
/// independently without constructing the full server.
Router signalPairingRoutes({
  required SignalChannel signalChannel,
  required SessionService sessions,
  required PageRegistry pageRegistry,
  String appName = 'DartClaw',
}) {
  final router = Router();

  // GET /pairing — Signal pairing/status page.
  router.get('/pairing', (Request request) async {
    final sidebarData = await buildSidebarData(sessions);
    final phone = signalChannel.config.phoneNumber;
    final error = request.requestedUri.queryParameters['error'];

    // SMS registration steps (captcha, verify) are hidden — TD-035.
    // The step query param and routes still exist for future use.
    // final step = request.requestedUri.queryParameters['step'];

    var isConnected = false;
    String? connectedPhone;
    String? linkDeviceUri;
    String? templateError = error;

    var showReconnecting = false;

    try {
      final reachable = await signalChannel.sidecar.healthCheck();
      if (reachable) {
        final registered = await signalChannel.sidecar.isAccountRegistered();
        if (registered) {
          isConnected = true;
          connectedPhone = signalChannel.sidecar.registeredPhone ?? phone;
          templateError = null;
        } else {
          linkDeviceUri = await signalChannel.sidecar.getLinkDeviceUri();
        }
      } else if (signalChannel.sidecar.wasPaired && signalChannel.sidecar.restartCount > 0) {
        showReconnecting = true;
      }
    } catch (e) {
      templateError = 'Failed to check signal-cli status: $e';
    }

    final html = signalPairingTemplate(
      isConnected: isConnected,
      showReconnecting: showReconnecting,
      connectedPhone: connectedPhone,
      linkDeviceUri: linkDeviceUri,
      error: templateError,
      restartAttempt: signalChannel.sidecar.restartCount,
      maxRestartAttempts: signalChannel.sidecar.maxRestartAttempts,
      sidebarData: sidebarData,
      navItems: pageRegistry.navItems(activePage: 'Settings'),
      fragmentOnly: wantsFragment(request),
      appName: appName,
    );

    return Response.ok(html, headers: htmlHeaders);
  });

  // GET /pairing/poll — lightweight status check for HTMX polling.
  // Returns 204 while waiting (HTMX skips swap), or renders the full
  // pairing page when status changes to connected.
  router.get('/pairing/poll', (Request request) async {
    try {
      final reachable = await signalChannel.sidecar.healthCheck();
      if (!reachable || !await signalChannel.sidecar.isAccountRegistered()) {
        return Response(204);
      }
    } catch (_) {
      return Response(204);
    }
    // Connected — render full page so HTMX can swap to "Connected" state.
    final sidebarData = await buildSidebarData(sessions);
    final html = signalPairingTemplate(
      isConnected: true,
      connectedPhone: signalChannel.sidecar.registeredPhone ?? signalChannel.config.phoneNumber,
      sidebarData: sidebarData,
      navItems: pageRegistry.navItems(activePage: 'Settings'),
      fragmentOnly: wantsFragment(request),
      appName: appName,
    );
    return Response.ok(html, headers: htmlHeaders);
  });

  // POST /pairing/register — trigger SMS verification.
  router.post('/pairing/register', (Request request) async {
    final body = await request.readAsString();
    final params = Uri.splitQueryString(body);
    final phone = params['phone']?.trim();
    final captcha = params['captcha']?.trim();
    if (phone == null || phone.isEmpty) {
      return Response.found('/signal/pairing?error=${Uri.encodeQueryComponent('Phone number is required')}');
    }
    try {
      await signalChannel.sidecar.requestSmsVerification(
        phone: phone,
        captcha: captcha != null && captcha.isNotEmpty ? captcha : null,
      );
      return Response.found('/signal/pairing?step=verify');
    } catch (e) {
      if (e.toString().contains('aptcha')) {
        return Response.found('/signal/pairing?step=captcha&phone=${Uri.encodeQueryComponent(phone)}');
      }
      final msg = Uri.encodeQueryComponent('Failed to send SMS: $e');
      return Response.found('/signal/pairing?error=$msg');
    }
  });

  // POST /pairing/register-voice — trigger voice call verification.
  router.post('/pairing/register-voice', (Request request) async {
    final body = await request.readAsString();
    final params = Uri.splitQueryString(body);
    final phone = params['phone']?.trim();
    final captcha = params['captcha']?.trim();
    if (phone == null || phone.isEmpty) {
      return Response.found('/signal/pairing?error=${Uri.encodeQueryComponent('Phone number is required')}');
    }
    try {
      await signalChannel.sidecar.requestVoiceVerification(
        phone: phone,
        captcha: captcha != null && captcha.isNotEmpty ? captcha : null,
      );
      return Response.found('/signal/pairing?step=verify');
    } catch (e) {
      if (e.toString().contains('aptcha')) {
        return Response.found('/signal/pairing?step=captcha&phone=${Uri.encodeQueryComponent(phone)}');
      }
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

  // POST /pairing/disconnect — reset signal-cli and restart for re-pairing.
  router.post('/pairing/disconnect', (Request request) async {
    try {
      await signalChannel.disconnect();
      await signalChannel.connect();
      return Response.found('/signal/pairing');
    } catch (e) {
      final msg = Uri.encodeQueryComponent('Failed to disconnect: $e');
      return Response.found('/signal/pairing?error=$msg');
    }
  });

  // GET /pairing/qr — SVG QR code for the device link URI.
  router.get('/pairing/qr', (Request request) async {
    try {
      final uri = await signalChannel.sidecar.getLinkDeviceUri();
      if (uri == null) return Response.notFound('No link URI available');
      return Response.ok(_buildQrSvg(uri), headers: {'content-type': 'image/svg+xml'});
    } catch (_) {
      return Response.internalServerError(body: 'Failed to generate QR');
    }
  });

  return router;
}

/// Renders a [data] string as a plain SVG QR code (black on white).
String _buildQrSvg(String data) {
  final qr = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
  final img = QrImage(qr);
  final n = img.moduleCount;
  const quiet = 4; // spec mandates ≥4 module quiet zone
  final total = n + quiet * 2;
  final buf = StringBuffer()
    ..write(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'viewBox="0 0 $total $total" shape-rendering="crispEdges">',
    )
    ..write('<rect width="$total" height="$total" fill="white"/>')
    ..write('<g fill="black">');
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (img.isDark(y, x)) {
        buf.write('<rect x="${x + quiet}" y="${y + quiet}" width="1" height="1"/>');
      }
    }
  }
  buf.write('</g></svg>');
  return buf.toString();
}
