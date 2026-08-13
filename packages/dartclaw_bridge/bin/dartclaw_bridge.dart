import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';

/// In-container loopback bridge for one host-owned surface.
///
/// Started by the host through `docker exec -i`; stdin/stdout are the pipe.
/// Usage: `dartclaw_bridge --surface=<provider|mcp> --port=<port>`
Future<void> main(List<String> arguments) async {
  final options = _parse(arguments);
  if (options == null) {
    stderr.writeln('usage: dartclaw_bridge --surface=<provider|mcp> --port=<port>');
    exitCode = 64;
    return;
  }

  final runner = BridgeRunner(surface: options.surface, hostInput: stdin, hostOutput: stdout, port: options.port);
  ProcessSignal.sigterm.watch().listen((_) => runner.close());
  ProcessSignal.sigint.watch().listen((_) => runner.close());

  try {
    await runner.start();
  } on BridgeProtocolException catch (error) {
    stderr.writeln('bridge handshake failed: ${error.message}');
    await runner.close();
    exitCode = 69;
    return;
  }
  await runner.done;
}

({BridgeSurface surface, int port})? _parse(List<String> arguments) {
  BridgeSurface? surface;
  int? port;
  for (final argument in arguments) {
    if (argument.startsWith('--surface=')) {
      surface = BridgeSurface.fromWire(argument.substring('--surface='.length));
    } else if (argument.startsWith('--port=')) {
      port = int.tryParse(argument.substring('--port='.length));
    }
  }
  if (surface == null || port == null || port < 1 || port > 65535) return null;
  return (surface: surface, port: port);
}
