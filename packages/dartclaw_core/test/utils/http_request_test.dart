import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show httpRequest;
import 'package:test/test.dart';

void main() {
  group('httpRequest', () {
    late HttpServer server;
    late Uri baseUri;

    Uri path(String p) => baseUri.replace(path: p);

    tearDown(() async {
      await server.close(force: true);
    });

    test('GET returns status code and decoded body', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.write('hello body');
        await req.response.close();
      });

      final result = await httpRequest(path('/get'));
      expect(result.statusCode, 200);
      expect(result.body, 'hello body');
    });

    test('POST writes the request body and echoes it back', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      server.listen((req) async {
        final received = await utf8.decoder.bind(req).join();
        req.response.statusCode = 201;
        req.response.write('echo:$received');
        await req.response.close();
      });

      final result = await httpRequest(path('/post'), method: 'POST', body: 'payload-123');
      expect(result.statusCode, 201);
      expect(result.body, 'echo:payload-123');
    });

    test('forwards request headers verbatim', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      server.listen((req) async {
        final token = req.headers.value('x-custom-token');
        req.response.write(token ?? '<none>');
        await req.response.close();
      });

      final result = await httpRequest(path('/headers'), headers: const {'X-Custom-Token': 'abc-XYZ'});
      expect(result.body, 'abc-XYZ');
    });

    test('returns a non-2xx status instead of throwing', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      server.listen((req) async {
        req.response.statusCode = 503;
        req.response.write('unavailable');
        await req.response.close();
      });

      final result = await httpRequest(path('/error'));
      expect(result.statusCode, 503);
      expect(result.body, 'unavailable');
    });

    test('propagates TimeoutException when a step exceeds the timeout', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      server.listen((req) async {
        // Delay past the request timeout before responding.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        req.response.write('too late');
        await req.response.close();
      });

      await expectLater(
        httpRequest(path('/slow'), timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
