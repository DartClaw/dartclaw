import 'dart:io';

import 'package:shelf/shelf.dart';

/// Builds a GET [Request] carrying a faked shelf connection-info so auth code
/// can resolve the socket remote address.
///
/// [socketAddress] is the peer's IP; [path] defaults to `/api/sessions` (the
/// middleware suite's path) and is overridden to `/test` by the auth-utils
/// suite. The path is irrelevant to the remote-address / forwarded-header logic
/// under test.
Request authRequest({
  required String socketAddress,
  Map<String, String> headers = const {},
  String path = '/api/sessions',
}) {
  return Request(
    'GET',
    Uri.parse('http://localhost$path'),
    headers: headers,
    context: {'shelf.io.connection_info': FakeConnectionInfo(socketAddress)},
  );
}

/// Fakes [HttpConnectionInfo] for shelf connection-info plumbing. Remote/local
/// ports are fixed (443/3000); the remote address is parsed from the supplied
/// string.
class FakeConnectionInfo implements HttpConnectionInfo {
  FakeConnectionInfo(String address) : remoteAddress = InternetAddress.tryParse(address)!;

  @override
  final InternetAddress remoteAddress;

  @override
  final int remotePort = 443;

  @override
  final int localPort = 3000;
}
