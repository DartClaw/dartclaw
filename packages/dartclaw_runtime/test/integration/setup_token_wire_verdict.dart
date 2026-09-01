/// The raw-Bearer wire check's verdict, separated from the stored token and the
/// live endpoint the gate itself needs.
///
/// The gate is skipped by default, so the rule deciding what its result *means*
/// would otherwise be proven by nothing. A misread refusal is worse there than
/// no gate at all: it sends the operator back to re-run a check that cannot
/// answer differently, instead of returning the shipping decision the gate
/// exists to make. `setup_token_wire_verdict_test.dart` runs on every push.
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

/// What an upstream answer says about shipping container-mode Claude on a
/// subscription credential.
enum SetupTokenWireVerdict {
  /// The raw Bearer carried the call.
  accepted,

  /// The credential was turned away – ship the `x-api-key` fallback.
  rejected,

  /// The upstream answered something that is not about the credential.
  inconclusive,
}

/// Drives [adapter] with a minimal Messages turn and fails the calling test
/// with the verdict, so a gate run reports one of exactly three outcomes.
///
/// A refusal reaches here two ways and both mean the same thing: the adapter
/// raises [GatewayCredentialUnusable] for a 401 and for a 403 naming an
/// authentication error, while a 403 `permission_error` is deliberately
/// forwarded as a response — tearing a live container's authority down over a
/// plan restriction would be wrong at runtime, but for this gate it is still a
/// rejection of the raw Bearer.
Future<void> checkSetupTokenOnTheWire(ProviderAdapter adapter) async {
  final GatewayResponse response;
  try {
    response = await adapter.handle(minimalMessagesRequest());
  } on GatewayCredentialUnusable catch (failure) {
    fail(setupTokenWireRejection(failure.remediation));
  }
  final body = await utf8.decodeStream(response.body);
  final outcome = 'HTTP ${response.status}: $body';
  final verdict = classifySetupTokenWireStatus(response.status);
  if (verdict == SetupTokenWireVerdict.rejected) fail(setupTokenWireRejection(outcome));
  if (verdict == SetupTokenWireVerdict.inconclusive) {
    fail(
      'INCONCLUSIVE – the upstream answered neither acceptance nor a refusal of the credential ($outcome). '
      'A rate limit or an outage is not an answer to the question this gate asks. Re-run.',
    );
  }
  expect(verdict, SetupTokenWireVerdict.accepted, reason: 'ACCEPTED – $outcome');
}

/// The verdict [status] carries.
///
/// A 401 and a 403 both mean the credential was turned away, and both answer
/// the gate. A `setup-token` authorized for Claude Code alone is refused as a
/// 403 `permission_error` — arguably the likeliest way a raw Bearer is turned
/// away here — so reading a 403 as inconclusive would hide the answer behind a
/// re-run that cannot produce a different one. Everything else non-2xx says
/// nothing about the wire: a rate limit or an upstream outage must never be
/// recorded as a shipping decision.
SetupTokenWireVerdict classifySetupTokenWireStatus(int status) {
  if (status >= 200 && status < 300) return SetupTokenWireVerdict.accepted;
  if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) return SetupTokenWireVerdict.rejected;
  return SetupTokenWireVerdict.inconclusive;
}

/// The REJECTED verdict, carrying the decision a rejection makes.
///
/// One author for both refusal paths, so the operator meets the same shipping
/// decision whichever way the refusal arrived. [refusal] names what came back.
String setupTokenWireRejection(String refusal) =>
    'REJECTED – Anthropic refused the stored setup-token presented as "authorization: Bearer" '
    'with the "${AnthropicMessagesAdapter.oauthBeta}" beta ($refusal).\n'
    'Documented fallback: ship containerized Claude on x-api-key mediation and name the raw-Bearer '
    'rejection in its remediation. Host-mode Claude is unaffected.';

/// The API version every Messages request must declare.
///
/// The adapter injects the credential and the OAuth beta but never this: in
/// production it arrives from the container's own client, so a gate that omits
/// it is answered `400 anthropic-version: header is required` before the
/// credential is ever judged — an INCONCLUSIVE the gate can never escape.
const anthropicVersion = '2023-06-01';

/// The smallest turn that still exercises the mediated Messages path.
///
/// Headers carry what a container client supplies and the adapter does not:
/// the API version and the content type. Anything the adapter injects
/// (`authorization`, `anthropic-beta`) is deliberately absent — supplying it
/// here would test this request instead of the mediation under gate.
GatewayRequest minimalMessagesRequest() => GatewayRequest(
  principal: const GatewayPrincipal(
    sessionId: 'setup-token-wire-check',
    providerId: 'claude',
    policy: ExecutionPolicy.container('workspace'),
  ),
  method: 'POST',
  path: '/v1/messages',
  headers: const {
    'anthropic-version': [anthropicVersion],
    'content-type': ['application/json'],
  },
  body: Stream.value(
    utf8.encode(
      jsonEncode({
        'model': 'claude-haiku-4-5',
        'max_tokens': 1,
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
      }),
    ),
  ),
);
