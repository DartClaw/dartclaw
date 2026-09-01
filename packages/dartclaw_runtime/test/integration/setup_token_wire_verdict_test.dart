import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

import 'setup_token_wire_verdict.dart';

/// Proves the verdict the raw-Bearer wire check reports, against a fake upstream.
///
/// The gate it serves needs a stored token and the real endpoint, so it is
/// skipped by default and could stay silently broken for a whole release. This
/// suite is deliberately credential-free and untagged: it drives the same
/// adapter the gate drives, over each answer the endpoint can give, and asserts
/// the operator is handed the right one of the three outcomes.
void main() {
  test('a scope-restricted setup-token reports REJECTED, not INCONCLUSIVE', () async {
    // The likeliest refusal shape, and the one the adapter forwards rather than
    // raises: Anthropic authenticated the token and then refused the call,
    // because a `setup-token` may be authorized for Claude Code alone. That is
    // still the raw Bearer failing to carry this call — the answer the gate
    // exists to get — so it must not be filed as "re-run and see".
    final adapter = _adapterAnswering(
      status: 403,
      body:
          '{"type":"error","error":{"type":"permission_error",'
          '"message":"This credential is only authorized for use with Claude Code"}}',
    );

    await expectLater(checkSetupTokenOnTheWire(await adapter), _failsWithRejected);
  });

  test('a credential the API will not authenticate reports the same REJECTED decision', () async {
    // The adapter raises this one instead of forwarding it, so the two refusal
    // paths must be proven to land on one verdict.
    final adapter = _adapterAnswering(status: 401, body: '{"type":"error","error":{"type":"authentication_error"}}');

    await expectLater(checkSetupTokenOnTheWire(await adapter), _failsWithRejected);
  });

  test('a rate limit stays INCONCLUSIVE', () async {
    final adapter = _adapterAnswering(status: 429, body: '{"type":"error","error":{"type":"rate_limit_error"}}');

    await expectLater(checkSetupTokenOnTheWire(await adapter), _failsWith('INCONCLUSIVE'));
  });

  test('an upstream outage stays INCONCLUSIVE', () async {
    final adapter = _adapterAnswering(status: 503, body: 'upstream unavailable');

    await expectLater(checkSetupTokenOnTheWire(await adapter), _failsWith('INCONCLUSIVE'));
  });

  test('an accepted raw Bearer passes the gate', () async {
    final adapter = _adapterAnswering(status: 200, body: '{"type":"message","content":[]}');

    await checkSetupTokenOnTheWire(await adapter);
  });

  test('the request the gate sends declares the API version, so it can reach a verdict at all', () async {
    // Regression: without `anthropic-version` the endpoint answers 400 before
    // judging the credential, so every real run reported INCONCLUSIVE and the
    // gate could never return the shipping decision it exists to make. The
    // adapter injects the credential and the beta, never this — it arrives from
    // the container's client in production and from this request under gate.
    final received = <String, List<String>>{};
    final adapter = await _adapterAnswering(
      status: 200,
      body: '{"type":"message","content":[]}',
      onRequest: received.addAll,
    );

    await checkSetupTokenOnTheWire(adapter);

    expect(received['anthropic-version'], [anthropicVersion]);
    expect(received['anthropic-beta'], contains(AnthropicMessagesAdapter.oauthBeta));
  });
}

/// A refusal must reach the operator as the shipping decision, not as prose.
final _failsWithRejected = throwsA(
  isA<TestFailure>().having(
    (failure) => failure.message,
    'message',
    allOf(startsWith('REJECTED'), contains('x-api-key'), isNot(contains(_setupToken))),
  ),
);

Matcher _failsWith(String verdict) =>
    throwsA(isA<TestFailure>().having((failure) => failure.message, 'message', startsWith(verdict)));

/// A sentinel token, so a verdict leaking the credential into a release PR
/// fails here first.
const _setupToken = 'sk-ant-oat01-WIRE-CHECK-SENTINEL-4d17';

/// The gate's own adapter, pointed at an upstream that answers once with
/// [status] and [body].
Future<ProviderAdapter> _adapterAnswering({
  required int status,
  required String body,
  void Function(Map<String, List<String>> headers)? onRequest,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    if (onRequest != null) {
      final headers = <String, List<String>>{};
      request.headers.forEach((name, values) => headers[name.toLowerCase()] = values);
      onRequest(headers);
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  });

  final adapter = AnthropicMessagesAdapter(
    credential: ProviderCredentialSource(
      () => CredentialResolution.subscription(CredentialEntry.subscription(token: _setupToken)),
    ),
    upstream: Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${server.port}'),
  );
  addTearDown(adapter.dispose);
  return adapter;
}
