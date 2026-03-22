import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'page_registry.dart';
import 'web_routes.dart' show buildSidebarData;
import 'web_utils.dart';
import 'whatsapp_pairing.dart';

/// WhatsApp pairing page and status routes.
///
/// Extracted from [DartclawServer._buildHandler] for testability and
/// consistency with [signalPairingRoutes].
Router whatsappPairingRoutes({
  required WhatsAppChannel whatsAppChannel,
  required SessionService sessions,
  required PageRegistry pageRegistry,
  String appName = 'DartClaw',
}) {
  final router = Router();

  // GET /pairing — WhatsApp pairing/status page.
  router.get('/pairing', (Request request) async {
    final sidebarData = await buildSidebarData(sessions);
    final fragment = wantsFragment(request);
    final pairingCode = request.requestedUri.queryParameters['code'];

    // Sidecar crashed / restarting
    if (!whatsAppChannel.gowa.isRunning && whatsAppChannel.gowa.restartCount > 0) {
      return Response.ok(
        whatsappPairingTemplate(
          showReconnecting: true,
          restartAttempt: whatsAppChannel.gowa.restartCount,
          maxRestartAttempts: whatsAppChannel.gowa.maxRestartAttempts,
          sidebarData: sidebarData,
          navItems: pageRegistry.navItems(activePage: 'Settings'),
          fragmentOnly: fragment,
          appName: appName,
        ),
        headers: htmlHeaders,
      );
    }

    try {
      final status = await whatsAppChannel.gowa.getStatus();
      if (status.isLoggedIn) {
        return Response.ok(
          whatsappPairingTemplate(
            isConnected: true,
            connectedPhone: jidToPhone(whatsAppChannel.gowa.pairedJid ?? status.deviceId),
            sidebarData: sidebarData,
            navItems: pageRegistry.navItems(activePage: 'Settings'),
            fragmentOnly: fragment,
          ),
          headers: htmlHeaders,
        );
      }
      // GOWA reachable but not logged in — show QR + pairing code
      final loginQr = await whatsAppChannel.gowa.getLoginQr();
      // Use local proxy URL to avoid CSP img-src blocking.
      final proxyUrl = loginQr.url != null ? '/whatsapp/pairing/qr' : null;
      return Response.ok(
        whatsappPairingTemplate(
          qrImageUrl: proxyUrl,
          qrDuration: loginQr.durationSeconds,
          pairingCode: pairingCode,
          sidebarData: sidebarData,
          navItems: pageRegistry.navItems(activePage: 'Settings'),
          fragmentOnly: fragment,
          appName: appName,
        ),
        headers: htmlHeaders,
      );
    } catch (e) {
      return Response.ok(
        whatsappPairingTemplate(
          error: 'Failed to check GOWA status: $e',
          sidebarData: sidebarData,
          navItems: pageRegistry.navItems(activePage: 'Settings'),
          fragmentOnly: fragment,
          appName: appName,
        ),
        headers: htmlHeaders,
      );
    }
  });

  // GET /pairing/qr — proxy QR image from GOWA to avoid CSP issues.
  router.get('/pairing/qr', (Request request) async {
    try {
      final loginQr = await whatsAppChannel.gowa.getLoginQr();
      if (loginQr.url == null) return Response.notFound('No QR available');
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(loginQr.url!));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        final bytes = await resp.fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
        return Response.ok(bytes, headers: {'content-type': 'image/png', 'cache-control': 'no-store'});
      } finally {
        client.close();
      }
    } catch (e) {
      return Response.internalServerError(body: 'Failed to fetch QR');
    }
  });

  // GET /pairing/poll — lightweight status check for HTMX polling.
  // Returns 204 while waiting (HTMX skips swap), or renders full page
  // when pairing completes.
  router.get('/pairing/poll', (Request request) async {
    try {
      final status = await whatsAppChannel.gowa.getStatus();
      if (!status.isLoggedIn) return Response(204);
      // Connected — render full page.
      final sidebarData = await buildSidebarData(sessions);
      return Response.ok(
        whatsappPairingTemplate(
          isConnected: true,
          connectedPhone: jidToPhone(whatsAppChannel.gowa.pairedJid ?? status.deviceId),
          sidebarData: sidebarData,
          navItems: pageRegistry.navItems(activePage: 'Settings'),
          fragmentOnly: wantsFragment(request),
          appName: appName,
        ),
        headers: htmlHeaders,
      );
    } catch (e) {
      return Response(204);
    }
  });

  // POST /pairing/disconnect — reset GOWA and restart for re-pairing.
  router.post('/pairing/disconnect', (Request request) async {
    try {
      await whatsAppChannel.disconnect();
      await whatsAppChannel.connect();
      return Response.found('/whatsapp/pairing');
    } catch (e) {
      final msg = Uri.encodeQueryComponent('Failed to disconnect: $e');
      return Response.found('/whatsapp/pairing?error=$msg');
    }
  });

  // POST /pairing/code — request pairing code for a phone number.
  router.post('/pairing/code', (Request request) async {
    try {
      final body = await request.readAsString();
      final params = Uri.splitQueryString(body);
      final phone = params['phone'] ?? '';
      if (phone.isEmpty) {
        return Response.found('/whatsapp/pairing?error=${Uri.encodeQueryComponent('Phone number is required')}');
      }
      final result = await whatsAppChannel.gowa.requestPairingCode(phone);
      final code = result['code']?.toString() ?? result['pairing_code']?.toString();
      if (code != null) {
        return Response.found('/whatsapp/pairing?code=${Uri.encodeQueryComponent(code)}');
      }
      return Response.found('/whatsapp/pairing?error=${Uri.encodeQueryComponent('No pairing code returned')}');
    } catch (e) {
      final msg = Uri.encodeQueryComponent('Failed to get pairing code: $e');
      return Response.found('/whatsapp/pairing?error=$msg');
    }
  });

  return router;
}
