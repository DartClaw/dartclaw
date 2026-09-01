/// Example: drive a running DartClaw server over its HTTP API and SSE stream.
///
/// **Prerequisites**: a DartClaw server reachable at `DARTCLAW_SERVER`
/// (default `http://localhost:3333`) and a gateway token in `DARTCLAW_TOKEN`,
/// unless the gateway runs with `auth_mode: none`. Get one with
/// `dartclaw token show`.
library;

import 'dart:io';

import 'package:dartclaw_client/dartclaw_client.dart';

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
    final tasks = await client.getList('/api/tasks');
    print('${tasks.length} task(s) on the server.');

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
