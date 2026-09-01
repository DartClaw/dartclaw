import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('four unrelated rejections produce four distinct classifications', () {
    test('a 401 with an auth-expiry body reads as the credential being refused', () {
      final rejection = classifyCodexRejection(
        status: 401,
        body: '{"detail":"unauthorized_unknown"}',
        requestedModel: 'gpt-5-codex',
      );

      expect(rejection?.kind, CodexRejectionKind.authExpired);
      expect(rejection?.model, isNull);
    });

    test('a 429 with a plan usage-limit body is never re-authentication and never a contract break', () {
      final rejection = classifyCodexRejection(
        status: 429,
        body: '{"error":{"type":"usage_limit_reached","message":"You have hit your plan limit"}}',
      );

      expect(rejection?.kind, CodexRejectionKind.usageLimit);
      expect(rejection?.detail, isNot(contains('log in')));
      expect(rejection?.detail, isNot(contains('mediation')));
    });

    test('a non-401 4xx rejecting the bearer scheme reads as a broken mediation contract', () {
      final rejection = classifyCodexRejection(
        status: 403,
        body: '{"error":{"code":"use_agent_identity","message":"bearer authorization is no longer accepted"}}',
      );

      expect(rejection?.kind, CodexRejectionKind.contractBreak);
      expect(rejection?.detail, isNot(contains('expired')));
    });

    test('a model rejection names the rejected model verbatim', () {
      final rejection = classifyCodexRejection(
        status: 400,
        body: '{"error":{"message":"The model `gpt-5.1-codex` is not supported for a ChatGPT account"}}',
        requestedModel: 'gpt-5.1-codex',
      );

      expect(rejection?.kind, CodexRejectionKind.modelUnsupported);
      expect(rejection?.model, 'gpt-5.1-codex');
      expect(rejection?.describe(), contains('gpt-5.1-codex'));
    });

    test('the four are distinct and none is derived from another status code', () {
      final kinds = {
        classifyCodexRejection(status: 401, body: 'unauthorized')!.kind,
        classifyCodexRejection(status: 429, body: 'plan limit reached')!.kind,
        classifyCodexRejection(status: 403, body: 'use_agent_identity required')!.kind,
        classifyCodexRejection(status: 400, body: 'model not supported', requestedModel: 'm')!.kind,
      };

      expect(kinds, hasLength(4));
      // A 401 naming the scheme is the credential being refused, not the
      // contract moving: the contract break is answered under another status.
      expect(
        classifyCodexRejection(status: 401, body: 'use_agent_identity required')?.kind,
        CodexRejectionKind.authExpired,
      );
    });
  });

  group('a status the backend answered outranks whatever its prose also names', () {
    // Backends write one prose body for several conditions, so a refusal that
    // names two causes is routine. Each case below classified as the *other*
    // bucket before the status arms were made authoritative, and every one of
    // those buckets maps to no credential health at all: an operator waits out
    // a limit window that never resets while the credential is what expired.

    test('a 401 naming a quota is the credential being refused, not a plan limit', () {
      final rejection = classifyCodexRejection(status: 401, body: '{"detail":"quota exceeded"}');

      expect(rejection?.kind, CodexRejectionKind.authExpired);
    });

    test('a 401 naming the model is the credential being refused, not an unsupported model', () {
      final rejection = classifyCodexRejection(
        status: 401,
        body: 'the model is not available',
        requestedModel: 'gpt-5-codex',
      );

      expect(rejection?.kind, CodexRejectionKind.authExpired);
      expect(rejection?.model, isNull, reason: 'nothing about a refused credential is a verdict on the model');
    });

    test('a 429 naming the model is the plan limit, not an unsupported model', () {
      final rejection = classifyCodexRejection(
        status: 429,
        body: 'rate limit reached; this model is not available',
        requestedModel: 'gpt-5-codex',
      );

      expect(rejection?.kind, CodexRejectionKind.usageLimit);
    });

    test('a 403 naming both the auth scheme and the model is the mediation contract, not the model', () {
      final rejection = classifyCodexRejection(
        status: 403,
        body: 'use_agent_identity; model not supported',
        requestedModel: 'gpt-5-codex',
      );

      expect(rejection?.kind, CodexRejectionKind.contractBreak);
    });

    test('a 5xx naming the model is the backend failing, not an answer about the account', () {
      expect(classifyCodexRejection(status: 503, body: 'model not supported', requestedModel: 'gpt-5-codex'), isNull);
    });
  });

  group('unclassified and host-mode refusals', () {
    test('an unrecognized upstream error stays unclassified rather than defaulting into a bucket', () {
      expect(classifyCodexRejection(status: 500, body: '{"error":{"message":"internal"}}'), isNull);
      expect(classifyCodexRejection(status: 400, body: '{"error":{"message":"bad request"}}'), isNull);
    });

    test('a vendor-relayed model rejection classifies with no status at all', () {
      final rejection = classifyCodexRejection(
        body: '{"type":"turn.failed","error":{"message":"model gpt-5.1-codex is not supported"}}',
        requestedModel: 'gpt-5.1-codex',
      );

      expect(rejection?.kind, CodexRejectionKind.modelUnsupported);
      expect(rejection?.model, 'gpt-5.1-codex');
    });

    test('an unrelated vendor error is not classified as model-unsupported', () {
      expect(classifyCodexRejection(body: '{"type":"error","error":{"code":"stream_disconnected"}}'), isNull);
    });

    test('a container-authored model name is stripped and bounded before it can reach a log', () {
      // On the mediated boundary the model comes from the container's own
      // request body, and the diagnostic is written to an operator log.
      final rejection = classifyCodexRejection(
        status: 400,
        body: '{"error":{"message":"model not supported"}}',
        requestedModel: 'gpt\u001b[31m-5\nWARNING: fake operator line ${'x' * 200}',
      );

      expect(rejection?.kind, CodexRejectionKind.modelUnsupported);
      expect(rejection!.describe(), isNot(contains('\n')));
      expect(rejection.describe(), isNot(contains('\u001b')));
      expect(rejection.describe().length, lessThan(200));
    });

    test('no classification carries credential material', () {
      const body = '{"error":{"message":"unauthorized","token":"sk-codex-LEAKED","account_id":"acct-LEAKED"}}';
      final rejection = classifyCodexRejection(status: 401, body: body);

      expect(rejection!.describe(), isNot(contains('sk-codex-LEAKED')));
      expect(rejection.describe(), isNot(contains('acct-LEAKED')));
    });
  });
}
