import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:logging/logging.dart';
import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'page_registry.dart';
import 'sidebar_data_builder.dart';
import 'signal_pairing.dart';
import 'web_utils.dart';

final _log = Logger('signalPairing');

/// Signal pairing page routes.
///
/// Extracted from [DartclawServer.handler] so they can be tested
/// independently without constructing the full server.
Router signalPairingRoutes({
  required SignalChannel signalChannel,
  required SessionService sessions,
  required PageRegistry pageRegistry,
  bool tasksEnabled = false,
  String appName = 'DartClaw',
}) {
  final router = Router();

  // GET /pairing — Signal pairing/status page.
  router.get('/pairing', (Request request) async {
    final sidebarData = await buildMinimalSidebarData(sessions, tasksEnabled: tasksEnabled);
    final phone = signalChannel.config.phoneNumber;
    final error = request.requestedUri.queryParameters['error'];

    var isConnected = false;
    String? connectedPhone;
    String? linkDeviceUri;
    String? templateError = error;

    var showReconnecting = false;
    var showStatusUnavailable = false;

    if (!signalChannel.sidecar.isRunning && signalChannel.sidecar.wasPaired && signalChannel.sidecar.restartCount > 0) {
      showReconnecting = true;
    } else if (signalChannel.sidecar.isRunning) {
      try {
        final reachable = await signalChannel.sidecar.healthCheck();
        if (reachable) {
          switch (await signalChannel.sidecar.registrationState()) {
            case SignalRegistrationState.registered:
              isConnected = true;
              connectedPhone = signalChannel.sidecar.registeredPhone ?? phone;
              templateError = null;
            case SignalRegistrationState.unregistered:
              linkDeviceUri = await signalChannel.sidecar.getLinkDeviceUri();
            case SignalRegistrationState.unknown:
              showStatusUnavailable = true;
          }
        } else if (signalChannel.sidecar.wasPaired && signalChannel.sidecar.restartCount > 0) {
          showReconnecting = true;
        }
      } catch (e) {
        // Sidecar unreachable / status probe failed — fall through to the clean
        // "signal-cli Not Reachable" setup card (templateError stays as the
        // request's ?error= value, if any) rather than leaking the raw exception
        // into the UI. Log server-side for diagnosability.
        _log.fine('signal-cli status check failed: $e');
      }
    }

    final html = signalPairingTemplate(
      isConnected: isConnected,
      showReconnecting: showReconnecting,
      showStatusUnavailable: showStatusUnavailable,
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
      if (!reachable || await signalChannel.sidecar.registrationState() != SignalRegistrationState.registered) {
        return Response(204);
      }
    } catch (e) {
      return Response(204);
    }
    // Connected — render full page so HTMX can swap to "Connected" state.
    final sidebarData = await buildMinimalSidebarData(sessions, tasksEnabled: tasksEnabled);
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
    } catch (e) {
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
