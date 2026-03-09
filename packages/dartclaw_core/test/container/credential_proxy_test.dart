import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/container/credential_proxy.dart';
import 'package:test/test.dart';

void main() {
  group('CredentialProxy', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('credential_proxy_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('start and stop manage socket lifecycle', () async {
      final proxy = CredentialProxy(
        socketPath: '${tempDir.path}/proxy.sock',
        apiKey: 'test-key',
        targetHost: '127.0.0.1',
        targetPort: 65535,
      );

      await proxy.start();
      expect(File(proxy.socketPath).existsSync(), isTrue);

      await proxy.stop();
      expect(File(proxy.socketPath).existsSync(), isFalse);
    });

    test('header injection forwards x-api-key and authorization', () async {
      late HttpHeaders headers;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        headers = request.headers;
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(() => upstream.close(force: true));

      final proxy = CredentialProxy(
        socketPath: '${tempDir.path}/proxy.sock',
        apiKey: 'secret',
        targetHost: '127.0.0.1',
        targetPort: upstream.port,
      );
      await proxy.start();
      addTearDown(proxy.stop);

      final response = await _sendUnixRequest(proxy.socketPath, path: '/v1/messages');

      expect(response.statusCode, 200);
      expect(response.body, 'ok');
      expect(headers.value('x-api-key'), 'secret');
      expect(headers.value('authorization'), 'Bearer secret');
      expect(proxy.requestCount, 1);
      expect(proxy.errorCount, 0);
    });

    test('returns 502 and increments error count on upstream failure', () async {
      final proxy = CredentialProxy(
        socketPath: '${tempDir.path}/proxy.sock',
        apiKey: 'secret',
        targetHost: '127.0.0.1',
        targetPort: 65535,
      );
      await proxy.start();
      addTearDown(proxy.stop);

      final response = await _sendUnixRequest(proxy.socketPath, path: '/v1/messages');

      expect(response.statusCode, 502);
      expect(response.body, 'Bad Gateway');
      expect(proxy.requestCount, 1);
      expect(proxy.errorCount, 1);
    });

    test('cleans up stale socket on start', () async {
      final socketPath = '${tempDir.path}/proxy.sock';
      await File(socketPath).writeAsString('stale');

      final proxy = CredentialProxy(
        socketPath: socketPath,
        apiKey: 'secret',
        targetHost: '127.0.0.1',
        targetPort: 65535,
      );
      await proxy.start();
      addTearDown(proxy.stop);

      expect(File(socketPath).existsSync(), isTrue);
      expect(File(socketPath).lengthSync(), isNot(equals(5)));
    });

    test('request and error counters track mixed traffic', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(() => upstream.close(force: true));

      final proxy = CredentialProxy(
        socketPath: '${tempDir.path}/proxy.sock',
        apiKey: 'secret',
        targetHost: '127.0.0.1',
        targetPort: upstream.port,
      );
      await proxy.start();

      await _sendUnixRequest(proxy.socketPath, path: '/ok');
      await upstream.close(force: true);
      await _sendUnixRequest(proxy.socketPath, path: '/fail');

      expect(proxy.requestCount, 2);
      expect(proxy.errorCount, 1);

      await proxy.stop();
      expect(File(proxy.socketPath).existsSync(), isFalse);
    });

    test('oauth passthrough mode does not inject api key headers', () async {
      late HttpHeaders headers;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        headers = request.headers;
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(() => upstream.close(force: true));

      final proxy = CredentialProxy(
        socketPath: '${tempDir.path}/proxy.sock',
        targetHost: '127.0.0.1',
        targetPort: upstream.port,
      );
      await proxy.start();
      addTearDown(proxy.stop);

      final response = await _sendUnixRequest(
        proxy.socketPath,
        path: '/v1/messages',
        headers: {'Authorization': 'Bearer oauth-token'},
      );

      expect(response.statusCode, 200);
      expect(headers.value('authorization'), 'Bearer oauth-token');
      expect(headers.value('x-api-key'), isNull);
    });
  });
}

Future<_HttpResponse> _sendUnixRequest(
  String socketPath, {
  required String path,
  String method = 'GET',
  String body = '',
  Map<String, String> headers = const {},
}) async {
  final socket = await Socket.connect(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
  final contentLength = utf8.encode(body).length;
  final headerBuffer = StringBuffer()
    ..write('Host: localhost\r\n')
    ..write('Connection: close\r\n')
    ..write('Content-Length: $contentLength\r\n');
  for (final entry in headers.entries) {
    headerBuffer.write('${entry.key}: ${entry.value}\r\n');
  }
  socket.write(
    '$method $path HTTP/1.1\r\n'
    '${headerBuffer.toString()}'
    '\r\n'
    '$body',
  );
  await socket.flush();
  final raw = await utf8.decoder.bind(socket).join();

  final parts = raw.split('\r\n\r\n');
  final headerLines = parts.first.split('\r\n');
  final statusCode = int.parse(headerLines.first.split(' ')[1]);
  final encodedBody = parts.length > 1 ? parts.sublist(1).join('\r\n\r\n') : '';

  return _HttpResponse(statusCode, _decodeChunkedBody(encodedBody));
}

String _decodeChunkedBody(String encodedBody) {
  final lines = const LineSplitter().convert(encodedBody.replaceAll('\r\n', '\n'));
  final buffer = StringBuffer();
  var index = 0;
  while (index < lines.length) {
    final size = int.tryParse(lines[index], radix: 16);
    if (size == null || size == 0) {
      break;
    }
    index++;
    if (index >= lines.length) {
      break;
    }
    buffer.write(lines[index]);
    index++;
  }
  return buffer.toString();
}

class _HttpResponse {
  final int statusCode;
  final String body;

  const _HttpResponse(this.statusCode, this.body);
}
