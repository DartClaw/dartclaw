// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw/dartclaw.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  final demoMode = args.contains('--demo');
  final port = _readPort(args);
  final server = await shelf_io.serve(_handler(demoMode: demoMode), '127.0.0.1', port);
  print('serving http://${server.address.host}:${server.port}/turn demo=$demoMode');
}

Handler _handler({required bool demoMode}) {
  return (request) async {
    if (request.method != 'POST' || request.url.path != 'turn') {
      return Response.notFound('POST /turn');
    }

    final prompt = (await request.readAsString()).trim();
    if (prompt.isEmpty) return Response(400, body: 'request body must contain a prompt\n');

    if (demoMode) {
      return Response.ok(
        jsonEncode({'mode': 'demo', 'reply': 'DartClaw hosts agent turns behind Dart services.'}),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }

    final harness = ClaudeCodeHarness(cwd: Directory.current.path);
    await harness.start();
    final stream = StreamController<List<int>>();
    final sub = harness.events.listen((event) {
      if (event case DeltaEvent(:final text)) {
        stream.add(utf8.encode('data: ${jsonEncode(text)}\n\n'));
      }
    });

    unawaited(
      harness
          .turn(
            sessionId: 'shelf-server-example',
            messages: [
              {'role': 'user', 'content': prompt},
            ],
            systemPrompt: 'You are a concise assistant in a minimal Shelf SDK example.',
          )
          .whenComplete(() async {
            await sub.cancel();
            await harness.dispose();
            await stream.close();
          }),
    );

    return Response.ok(stream.stream, headers: {'content-type': 'text/event-stream; charset=utf-8'});
  };
}

int _readPort(List<String> args) {
  final index = args.indexOf('--port');
  if (index == -1) return 8095;
  if (index + 1 >= args.length) {
    stderr.writeln('usage: dart run shelf_server [--demo] [--port 8095]');
    exit(64);
  }
  return int.parse(args[index + 1]);
}
