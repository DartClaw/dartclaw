/// Example: drive a running DartClaw server over its HTTP API and SSE stream.
///
/// **Prerequisites**: a DartClaw server reachable at `DARTCLAW_SERVER`
/// (default `http://localhost:3333`) and a gateway token in `DARTCLAW_TOKEN`,
/// unless the gateway runs with `auth_mode: none`. Get one with
/// `dartclaw token show`.
library;

import 'dart:io';

import 'package:dartclaw/dartclaw.dart';

void main() async {
  final client = DartclawApiClient(
    baseUri: Uri.parse(Platform.environment['DARTCLAW_SERVER'] ?? 'http://localhost:3333'),
    token: Platform.environment['DARTCLAW_TOKEN'],
  );

  if (!await client.probeHealth(treatUnauthorizedAsReachable: false)) {
    print('No DartClaw server answered. Start one with `dartclaw serve`.');
    return;
  }

  try {
    final sessions = await client.getList('/api/sessions');
    print('${sessions.length} session(s) on the server.');

    // Follow the server's event stream until the first event arrives.
    await for (final event in client.streamEvents('/api/events').take(1)) {
      print('event: ${event['type']}');
    }
  } on DartclawApiException catch (error) {
    // `message` never contains the bearer token (it can contain `baseUri`).
    print('Request failed (${error.code ?? error.statusCode}): ${error.message}');
    exitCode = 1;
  }
}
