import 'dart:io';

import 'package:dartclaw_server/src/auth/auth_utils.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('constantTimeEquals', () {
    test('returns true for equal strings', () {
      expect(constantTimeEquals('abc123', 'abc123'), isTrue);
      expect(constantTimeEquals('', ''), isTrue);
      expect(constantTimeEquals('Hej 👋', 'Hej 👋'), isTrue);
    });

    test('returns false for different strings', () {
      expect(constantTimeEquals('abc123', 'abc124'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', 'value'), isFalse);
      expect(constantTimeEquals('Hej 👋', 'Hej 😀'), isFalse);
    });
  });

  group('readBounded', () {
    test('returns body under the limit', () async {
      final request = Request('POST', Uri.parse('http://localhost/test'), body: 'hello');
      expect(await readBounded(request, 10), 'hello');
    });

    test('returns body at the limit', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        body: 'hello',
        headers: {'content-length': '5'},
      );
      expect(await readBounded(request, 5), 'hello');
    });

    test('returns null when content-length exceeds limit', () async {
      final request = Request(
        'POST',
        Uri.parse('http://localhost/test'),
        body: 'hello!',
        headers: {'content-length': '6'},
      );
      expect(await readBounded(request, 5), isNull);
    });

    test('returns empty body when request is empty', () async {
      final request = Request('POST', Uri.parse('http://localhost/test'), body: '');
      expect(await readBounded(request, 1), '');
    });

    test('returns null when streamed body exceeds exact boundary', () async {
      final request = Request('POST', Uri.parse('http://localhost/test'), body: 'hello!');
      expect(await readBounded(request, 5), isNull);
    });
  });

  group('requestRemoteKey', () {
    test('uses socket address when no trusted proxies configured', () {
      final request = _request(socketAddress: '192.168.1.50', headers: {'x-forwarded-for': '1.2.3.4'});

      expect(requestRemoteKey(request), '192.168.1.50');
    });

    test('uses forwarded-for when connecting IP is trusted proxy', () {
      final request = _request(socketAddress: '192.168.1.100', headers: {'x-forwarded-for': '10.0.0.1, 10.0.0.2'});

      expect(requestRemoteKey(request, trustedProxies: const ['192.168.1.100']), '10.0.0.1');
    });

    test('ignores forwarded-for when connecting IP is not in trusted list', () {
      final request = _request(socketAddress: '192.168.1.50', headers: {'x-forwarded-for': '1.2.3.4'});

      expect(requestRemoteKey(request, trustedProxies: const ['192.168.1.100']), '192.168.1.50');
    });
  });
}

Request _request({required String socketAddress, Map<String, String> headers = const {}}) {
  return Request(
    'GET',
    Uri.parse('http://localhost/test'),
    headers: headers,
    context: {'shelf.io.connection_info': _FakeConnectionInfo(socketAddress)},
  );
}

class _FakeConnectionInfo implements HttpConnectionInfo {
  @override
  final InternetAddress remoteAddress;

  @override
  final int remotePort = 443;

  @override
  final int localPort = 3000;

  _FakeConnectionInfo(String address) : remoteAddress = InternetAddress.tryParse(address)!;
}
