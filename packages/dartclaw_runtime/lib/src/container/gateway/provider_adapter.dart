import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import '../../codex_rejection.dart';
import '../../task/codex_refresh_authority.dart' show CodexSubscriptionCredential;
import 'gateway_models.dart';

/// What the gateway needs from a provider surface: it answers requests and owns
/// an upstream client it must release.
abstract interface class ProviderMediator implements GatewaySurfaceHandler {
  /// Why this adapter cannot mediate for a container right now, or `null` when
  /// it can.
  ///
  /// Read at authority registration so an unusable provider configuration is
  /// refused before a container exists – not discovered mid-turn, by which
  /// point the execution has already been admitted on a promise the host
  /// cannot keep. The reason is surfaced to operators, so it must name the
  /// remedy without naming any credential.
  String? get unavailableReason;

  /// The operator command that would make this adapter mediable, or `null` when
  /// it already can. Reported alongside a refusal so the credential-health
  /// surfaces can render the fix on its own.
  String? get credentialRemediation;

  Future<void> dispose();
}

/// Where an adapter's presented credential comes from.
///
/// Two views of one source. [resolve] answers admission synchronously — is a
/// credential configured for this provider at all — while [present] is awaited
/// immediately before injection, so a source whose token rotates can refresh it
/// there without admission having to wait on a network round-trip. The default
/// [present] has nothing to refresh and returns what [resolve] returns.
class ProviderCredentialSource {
  new(this._resolve);

  /// A source presenting a configured API key, and nothing when [key] is absent.
  new apiKey(String? Function() key)
    : this(() {
        final value = key();
        return value == null || value.isEmpty
            ? const CredentialResolution.unavailable(CredentialUnavailableReason.noneConfigured)
            : CredentialResolution.apiKey(value);
      });

  final CredentialResolution Function() _resolve;

  /// The credential resolvable without refreshing anything.
  CredentialResolution resolve() => _resolve();

  /// The credential to present on the request being handled now.
  Future<CredentialResolution> present() async => resolve();
}

/// Host-side provider mediation for one container authority's provider pipe.
///
/// An adapter owns its upstream, its protocol, and its credential. A container
/// cannot name a destination, supply its own authentication, or reach anything
/// this adapter does not already know how to talk to — the request shape is the
/// only thing that crosses.
///
/// `base` on purpose: credential injection and header stripping happen in
/// [handle], and a subclass that replaced it would quietly reopen the boundary.
/// Subclasses supply protocol details, never request flow.
abstract base class ProviderAdapter implements ProviderMediator {
  new({
    required this.providerId,
    required this.upstream,
    required ProviderCredentialSource credential,
    this.credentialsDir,
    HttpClient? client,
  }) : _credential = credential,
       _client = client ?? HttpClient();

  static final _log = Logger('ProviderAdapter');

  /// Provider whose containerized clients this adapter serves.
  ///
  /// The configured provider id, not its family: an alias resolves its own
  /// `providers.<id>.auth` and its refusals name the entry an operator would
  /// edit.
  final String providerId;

  /// The credential family [providerId] resolves to, which names the operator
  /// command a refusal points at when the provider is an alias.
  String get providerFamily;

  /// The dedicated subscription store this adapter's credential is resolved
  /// from, when the deployment knows it.
  ///
  /// `data_dir` selects that directory, so a refusal that names no path cannot
  /// distinguish "never stored" from "stored under a different `data_dir`".
  final String? credentialsDir;

  /// Fixed upstream origin, pinned when the adapter is built.
  final Uri upstream;

  /// The single credential this authority presents, resolved per
  /// `providers.<id>.auth`. Subscription and API key are both mediable — what
  /// admission requires is that exactly one of them is presentable.
  final ProviderCredentialSource _credential;
  final HttpClient _client;

  @override
  BridgeSurface get surface => BridgeSurface.provider;

  /// Request paths this provider's protocol defines. Anything else is refused.
  Set<String> get allowedPaths;

  /// Every origin this adapter may send [credential] to, as `scheme://host:port`.
  ///
  /// A composed target outside the set is refused before a connection is
  /// opened, so a protocol subclass that got its own composition wrong cannot
  /// widen where a container's request can land. Scoped to the presented
  /// credential because an adapter with one backend per mode would otherwise
  /// accept either backend under either mode — sending a subscription token to
  /// the API-key upstream, or the reverse.
  Set<String> pinnedOriginsFor(CredentialResolution credential) => {originOf(upstream)};

  /// `scheme://host:port`, the comparable identity of a destination.
  static String originOf(Uri uri) => '${uri.scheme}://${uri.host}:${uri.port}';

  @override
  String? get credentialRemediation {
    final resolution = _credential.resolve();
    return resolution.isPresent ? null : _remediationFor(resolution.reason!);
  }

  @override
  String? get unavailableReason {
    final resolution = _credential.resolve();
    if (resolution.isPresent) return null;
    final remediation = _remediationFor(resolution.reason!);
    // Host execution is an alternative only where nothing is configured at all:
    // that is the one case the host gate lets the provider CLI's own login
    // rescue. A forced selection and an unrecognized `auth` value both refuse on
    // every boundary, so offering host mode there is a documented dead end.
    final hostAlternative = resolution.reason == CredentialUnavailableReason.noneConfigured
        ? ' Or select execution: host for this agent.'
        : '';
    return 'containerized "$providerId" has no host-held credential to mediate with. $remediation$hostAlternative';
  }

  String _remediationFor(CredentialUnavailableReason reason) =>
      credentialRemediationFor(reason, providerId: providerId, family: providerFamily, credentialsDir: credentialsDir);

  /// Applies the provider's authentication to a host-to-provider request.
  ///
  /// [credential] always carries a secret, and its mode selects the scheme the
  /// provider accepts it under.
  void authenticate(HttpClientRequest request, CredentialResolution credential);

  /// Composes the upstream target for an already-allowed [path].
  ///
  /// The default replaces the whole upstream path, which is correct only for an
  /// upstream with no base path of its own. An adapter whose upstream carries
  /// one must override this — a whole-path replacement would silently drop it
  /// and send the request to the wrong place on the right host.
  ///
  /// [credential] is the one being presented on this request, so an adapter that
  /// speaks to different backends per credential mode can pick here.
  Uri composeTarget(String path, String? query, CredentialResolution credential) =>
      upstream.replace(path: path, query: query);

  /// Inspects an upstream refusal so the adapter can classify why it failed.
  ///
  /// [body] is backend-authored text and [requestBody] is container-authored:
  /// neither may reach a log, an audit entry, or a diagnostic verbatim.
  /// [credential] is the one the refused request presented, so a refusal can be
  /// read against the mode it was made under.
  ///
  /// Throwing [GatewayCredentialUnusable] here declares the credential
  /// terminally dead: the upstream's own answer is then discarded rather than
  /// forwarded, and the authority is torn down instead of left to re-fail every
  /// later request.
  void inspectRejection(int status, String body, List<int> requestBody, CredentialResolution credential) {}

  /// How many provider-side network-reaching tools [body] declares, in this
  /// adapter's own protocol shape.
  ///
  /// These execute at the provider rather than in the container, so
  /// `network:none` cannot contain them and any containerized execution must be
  /// refused before the request leaves the host. Only the count is returned:
  /// the declarations are container-authored strings and must not reach a log
  /// or an audit entry.
  int countNetworkTools(Object? body);

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    final path = _pathOnly(request.path);
    if (request.method.toUpperCase() != 'POST' || !allowedPaths.contains(path)) {
      throw GatewayDenied(status: 404, reason: 'path is not part of the $providerId provider surface');
    }

    final credential = await _credential.present();
    // Emptiness is checked here, not left to the resolution: a present-but-blank
    // secret would otherwise be injected as `Bearer null` or an empty key
    // instead of failing closed.
    final secret = credential.secret;
    if (secret == null || secret.isEmpty) {
      throw GatewayDenied(status: 502, reason: 'no host credential is configured for provider "$providerId"');
    }

    final rawBody = await _collect(request);
    // Every container profile gets this check: `network:none` is applied to all
    // of them, so the provider pipe is the only egress any of them has.
    if (request.principal.containerProfile != null) {
      final declared = countNetworkTools(_decodeBody(rawBody));
      if (declared > 0) {
        throw GatewayDenied(
          status: 403,
          reason: 'containerized execution declared $declared provider-side network tool(s)',
        );
      }
    }

    final target = composeTarget(path, _queryOnly(request.path), credential);
    if (!pinnedOriginsFor(credential).contains(originOf(target))) {
      throw GatewayDenied(status: 403, reason: 'request destination is not a pinned $providerId upstream');
    }
    final outbound = await _client.openUrl(request.method, target);
    outbound.followRedirects = false;
    _copyHeaders(request.headers, outbound);
    // Injection happens last and unconditionally: a client-supplied credential
    // was already dropped by _copyHeaders, so nothing it sent can survive here.
    authenticate(outbound, credential);
    outbound.contentLength = rawBody.length;
    outbound.add(rawBody);

    final response = await outbound.close();
    _log.fine('Gateway $providerId ${request.method} $path -> ${response.statusCode}');
    final headers = _responseHeaders(response);
    if (response.statusCode < 400) {
      return GatewayResponse(status: response.statusCode, headers: headers, body: response);
    }
    // A refusal is read here rather than streamed through: the reason it names
    // is what tells an operator which of several unrelated things went wrong,
    // and the client still receives the same bytes.
    final refusal = await response.fold(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    inspectRejection(response.statusCode, utf8.decode(refusal, allowMalformed: true), rawBody, credential);
    return GatewayResponse(status: response.statusCode, headers: headers, body: Stream.value(refusal));
  }

  @override
  Future<void> dispose() async => _client.close(force: true);

  Future<List<int>> _collect(GatewayRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request.body) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  void _copyHeaders(Map<String, List<String>> headers, HttpClientRequest outbound) {
    for (final entry in headers.entries) {
      // Lowercased here rather than relying on the caller: the strip is this
      // adapter's own guarantee, and a producer that handed over raw header
      // casing would otherwise forward `X-Api-Key` untouched.
      if (_droppedRequestHeaders.contains(entry.key.toLowerCase())) continue;
      for (final value in entry.value) {
        outbound.headers.add(entry.key, value);
      }
    }
  }

  Map<String, List<String>> _responseHeaders(HttpClientResponse response) {
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      if (_droppedResponseHeaders.contains(name.toLowerCase())) return;
      headers[name] = values;
    });
    return headers;
  }

  /// Decodes a request body so its tool declarations can be counted.
  ///
  /// A body the host cannot read is refused rather than forwarded: the network
  /// tool check is the only thing standing between a container and provider-run
  /// egress, and an undecodable body would silently count zero.
  static Object? _decodeBody(List<int> body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      throw const GatewayDenied(
        status: 400,
        reason: 'request body is not decodable JSON, so its provider-side tool declarations cannot be checked',
      );
    }
  }

  static String _pathOnly(String target) {
    final separator = target.indexOf('?');
    return separator == -1 ? target : target.substring(0, separator);
  }

  static String? _queryOnly(String target) {
    final separator = target.indexOf('?');
    return separator == -1 ? null : target.substring(separator + 1);
  }

  /// Client-supplied headers that must never reach the provider: credentials
  /// the container should not be able to choose, routing headers that could
  /// redirect the request, hop-by-hop headers the host re-derives, and any
  /// framing the host did not apply — the body is forwarded as the plain JSON
  /// the tool check read, so a declared encoding would describe other bytes.
  static const _droppedRequestHeaders = {
    'authorization',
    'content-encoding',
    'x-api-key',
    'openai-api-key',
    'api-key',
    'proxy-authorization',
    'cookie',
    // The account the credential belongs to: the host sets it from the token it
    // presents, and when that token carries none the container's own value
    // would otherwise be the one the backend read.
    'chatgpt-account-id',
    'host',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'upgrade',
    'te',
    'trailer',
    'content-length',
    'forwarded',
    'x-forwarded-host',
    'x-forwarded-for',
    'x-forwarded-proto',
  };

  /// Upstream response headers that must never be written back down the pipe.
  ///
  /// The pipe is the only channel that enters a `network:none` container, so a
  /// credential-bearing header an upstream, intermediary, or error page
  /// reflected back would be handed straight into the boundary the rest of this
  /// adapter exists to keep it out of. Dropped whether or not any known
  /// upstream reflects one.
  static const _droppedResponseHeaders = {
    'authorization',
    'x-api-key',
    'proxy-authenticate',
    // The client decoded the body on the way in (`autoUncompress`), so keeping
    // the encoding headers would describe bytes that no longer exist.
    'content-encoding',
    'content-md5',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'upgrade',
    'te',
    'trailer',
    'content-length',
    'set-cookie',
  };
}

/// Anthropic Messages mediation for containerized Claude.
final class AnthropicMessagesAdapter extends ProviderAdapter {
  new({
    required super.credential,
    Uri? upstream,
    super.client,
    super.credentialsDir,
    super.providerId = ProviderIdentity.claude,
  }) : super(upstream: upstream ?? defaultUpstream);

  static final Uri defaultUpstream = Uri.https('api.anthropic.com');

  @override
  String get providerFamily => ProviderIdentity.claude;

  /// The Messages beta under which a subscription token is accepted as a raw
  /// Bearer rather than an API key.
  static const oauthBeta = 'oauth-2025-04-20';

  static const _betaHeader = 'anthropic-beta';

  @override
  Set<String> get allowedPaths => const {'/v1/messages', '/v1/messages/count_tokens'};

  @override
  void authenticate(HttpClientRequest request, CredentialResolution credential) {
    if (credential.mode == CredentialMode.subscription) {
      request.headers.set('authorization', 'Bearer ${credential.secret!}');
      // Added rather than set: the client declares its own betas, and replacing
      // them would silently drop capabilities the turn was built around. Adding
      // is skipped when the client already named this one, so the value is not
      // sent twice.
      if (!(request.headers[_betaHeader]?.any((value) => value.split(',').map((v) => v.trim()).contains(oauthBeta)) ??
          false)) {
        request.headers.add(_betaHeader, oauthBeta);
      }
      return;
    }
    request.headers.set('x-api-key', credential.secret!);
  }

  /// A subscription credential the API refuses to *authenticate* is terminal,
  /// and is the only thing that makes a hard-expired `setup-token` fail closed.
  ///
  /// The stored Claude expiry is derived from a documented lifetime rather than
  /// read off the token, so the live refusal — not the expiry — is what a wrong
  /// derivation is caught by. Forwarding it would hand the container a bare 401
  /// and leave the authority mediating on a credential that can no longer work.
  ///
  /// An API-key deployment keeps forwarding the upstream's answer: DartClaw
  /// tracks no lifetime for an operator-managed key, and a refusal there is as
  /// likely to be about the request as about the credential.
  @override
  void inspectRejection(int status, String body, List<int> requestBody, CredentialResolution credential) {
    if (credential.mode != CredentialMode.subscription) return;
    if (!_refusesTheCredential(status, body)) return;
    final renewal = credentialRenewalFor(providerFamily, credentialsDir: credentialsDir);
    throw GatewayCredentialUnusable(
      providerId: providerId,
      remediation:
          'the Anthropic API refused the stored subscription credential for "$providerId"'
          '${renewal == null ? '.' : ' – $renewal'}',
    );
  }

  /// Whether the API's refusal is about the credential itself rather than what
  /// the account is allowed to do with it.
  ///
  /// A 401 is unambiguous and decides on its own. A 403 is not: Anthropic
  /// answers one as `permission_error` for a plan or organization restriction on
  /// a token that authenticated fine, so it is terminal only where the body
  /// names the authentication error — reading every 403 as a dead credential is
  /// how a plan restriction starts telling operators to run `claude setup-token`
  /// again. Same status-then-marker discipline as [classifyCodexRejection], so
  /// the two mediation boundaries answer this question the same way.
  static bool _refusesTheCredential(int status, String body) =>
      status == HttpStatus.unauthorized ||
      (status == HttpStatus.forbidden && body.toLowerCase().contains(_authenticationErrorMarker));

  /// Anthropic's error type for a credential it will not authenticate, as
  /// distinct from `permission_error`, which means authenticated but not
  /// permitted.
  static const _authenticationErrorMarker = 'authentication_error';

  /// Messages declares provider-hosted remote MCP connectors in a top-level
  /// `mcp_servers` array, separate from the client tools in `tools`.
  @override
  int countNetworkTools(Object? body) {
    var declared = _countNetworkToolFamilies(body);
    if (body is Map<Object?, Object?>) {
      final connectors = body['mcp_servers'];
      if (connectors is List<Object?>) declared += connectors.length;
    }
    return declared;
  }
}

/// A Codex subscription credential and the ChatGPT account it belongs to.
///
/// The account id travels with the token rather than being read again at
/// injection time, so the two headers a mediated request carries always come
/// from one read of a store whose token rotates one-time-use.
final class CodexSubscriptionResolution extends CredentialResolution {
  new(CodexSubscriptionCredential credential)
    : accountId = credential.accountId,
      super.subscription(CredentialEntry.subscription(token: credential.accessToken));

  final String? accountId;
}

/// OpenAI Responses mediation for containerized Codex.
///
/// Two backends, selected by what the host presents and by nothing else: an API
/// key goes to the OpenAI Platform, a ChatGPT subscription credential goes to
/// the ChatGPT backend, which refuses a Platform-scoped call and vice versa.
final class OpenAiResponsesAdapter extends ProviderAdapter {
  new({
    required super.credential,
    Uri? upstream,
    Uri? subscriptionUpstream,
    super.client,
    super.credentialsDir,
    super.providerId = ProviderIdentity.codex,
    this.onRejection,
  }) : subscriptionUpstream = subscriptionUpstream ?? defaultSubscriptionUpstream,
       super(upstream: upstream ?? defaultUpstream);

  static final Uri defaultUpstream = Uri.https('api.openai.com');

  @override
  String get providerFamily => ProviderIdentity.codex;

  /// The ChatGPT backend. It carries a base path, so a target composed against
  /// it must extend that path rather than replace it.
  static final Uri defaultSubscriptionUpstream = Uri.https('chatgpt.com', '/backend-api/codex');

  /// Client identity the ChatGPT backend expects from a Codex client.
  static const originator = 'codex_cli_rs';

  static const _accountHeader = 'chatgpt-account-id';
  static const _originatorHeader = 'originator';

  /// The container is configured against `<provider bridge>/v1`, so it sends
  /// `/v1/responses` while the ChatGPT backend serves `/responses`. The mapping
  /// belongs to the host-side pin: an unmapped path is refused, not forwarded.
  static const _backendPaths = {'/v1/responses': '/responses'};

  final Uri subscriptionUpstream;

  /// Where a classified backend refusal is reported, fire-and-forget.
  final void Function(CodexRejection rejection)? onRejection;

  @override
  Set<String> get allowedPaths => const {'/v1/responses'};

  /// One origin per mode, never both at once: the two backends refuse each
  /// other's credential, so a target composed for the wrong one is a bug the
  /// pin must catch rather than forward.
  @override
  Set<String> pinnedOriginsFor(CredentialResolution credential) => {
    ProviderAdapter.originOf(credential.mode == CredentialMode.subscription ? subscriptionUpstream : upstream),
  };

  @override
  Uri composeTarget(String path, String? query, CredentialResolution credential) {
    if (credential.mode != CredentialMode.subscription) {
      return super.composeTarget(path, query, credential);
    }
    final backendPath = _backendPaths[path];
    if (backendPath == null) {
      throw GatewayDenied(status: 404, reason: 'path is not part of the $providerId subscription surface');
    }
    return subscriptionUpstream.replace(path: '${subscriptionUpstream.path}$backendPath', query: query);
  }

  @override
  void authenticate(HttpClientRequest request, CredentialResolution credential) {
    request.headers.set('authorization', 'Bearer ${credential.secret!}');
    if (credential.mode != CredentialMode.subscription) return;
    final accountId = credential is CodexSubscriptionResolution ? credential.accountId : null;
    if (accountId != null) request.headers.set(_accountHeader, accountId);
    request.headers.set(_originatorHeader, originator);
  }

  /// Only a subscription refusal is classified.
  ///
  /// Every bucket [classifyCodexRejection] names is a ChatGPT-backend
  /// condition, and an API key is mediated against the OpenAI Platform instead
  /// — a different upstream, reached over a different scheme. Reporting a
  /// Platform refusal through that vocabulary would tell an operator their
  /// *stored subscription* was refused and send them to `dartclaw auth codex`,
  /// which writes a store this deployment never presents. An API-key deployment
  /// therefore keeps the upstream's own answer, exactly as the Claude boundary
  /// does: DartClaw tracks no lifetime for an operator-managed key, and a
  /// refusal there is as likely to be about the request as about the credential.
  @override
  void inspectRejection(int status, String body, List<int> requestBody, CredentialResolution credential) {
    if (credential.mode != CredentialMode.subscription) return;
    final rejection = classifyCodexRejection(status: status, body: body, requestedModel: _requestedModel(requestBody));
    if (rejection != null) onRejection?.call(rejection);
  }

  /// The model the turn asked for, taken from the request the container sent —
  /// naming it back is exact, where parsing it out of the refusal would not be.
  static String? _requestedModel(List<int> requestBody) {
    try {
      final decoded = jsonDecode(utf8.decode(requestBody, allowMalformed: true));
      final model = decoded is Map<Object?, Object?> ? decoded['model'] : null;
      return model is String && model.isNotEmpty ? model : null;
    } on FormatException {
      return null;
    }
  }

  /// Responses has no `mcp_servers` array: it declares provider-hosted remote
  /// MCP connectors as an ordinary `tools` entry of `type: mcp` carrying a
  /// `server_url`. The match is exact on `type` alone – a client's own bridge
  /// tools are named `mcp__<server>__<tool>` and must keep passing.
  @override
  int countNetworkTools(Object? body) => _countNetworkToolFamilies(body, extra: (tool) => tool['type'] == 'mcp');
}

/// Provider-side tool families that reach the network on the caller's behalf.
///
/// Matching is by prefix because both providers version these identifiers
/// (`web_search_20250305`).
///
/// Deliberately no `mcp` prefix: a client's *own* MCP tools serialize as
/// ordinary tool declarations named `mcp__<server>__<tool>` and execute in the
/// container against the scoped bridge, which is exactly what a restricted
/// execution is supposed to use. Provider-hosted remote connectors – the ones
/// that really are an egress path `network:none` cannot see – are shaped
/// differently per protocol and are counted by each adapter.
const _networkToolPrefixes = {'web_search', 'web_fetch', 'code_execution', 'code_interpreter'};

/// Counts entries in the top-level `tools` array that name a network-reaching
/// tool family, plus any an adapter's [extra] protocol-specific test accepts.
///
/// Both protocols declare server-side tools there, keyed by `type` (and, for
/// Anthropic, `name`).
int _countNetworkToolFamilies(Object? body, {bool Function(Map<Object?, Object?> tool)? extra}) {
  if (body is! Map<Object?, Object?>) return 0;
  final tools = body['tools'];
  if (tools is! List<Object?>) return 0;
  var declared = 0;
  for (final tool in tools) {
    if (tool is! Map<Object?, Object?>) continue;
    final namesFamily = const ['type', 'name'].any((field) {
      final value = tool[field];
      return value is String && _networkToolPrefixes.any(value.startsWith);
    });
    if (namesFamily || (extra?.call(tool) ?? false)) declared++;
  }
  return declared;
}
