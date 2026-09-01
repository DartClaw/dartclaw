/// Shared scaffolding for the container integration suites.
///
/// Every suite here runs real containers against a real Docker engine and
/// observes the boundary from outside it. What they share — engine probing,
/// image and bridge-binary provisioning, the authority wrapper, and the fake
/// provider upstream — lives here so the suites cannot drift into disagreeing
/// about how the boundary is assembled.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore, containerImageUidGid;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Host credential the Anthropic-facing suites plant and then grep for.
///
/// A credential that appears anywhere the container can read is a failure, so
/// the sentinels are deliberately distinctive.
const sentinelAnthropicCredential = 'sk-ant-SENTINEL-d41d8cd98f00b204e9800998ecf8427e';

/// Host credential the OpenAI-facing suites plant and then grep for.
const sentinelOpenAiCredential = 'sk-openai-SENTINEL-9e107d9d372bb6826bd81d3542a419d6';

/// Stored Claude `setup-token`, in the shape the dedicated store holds one.
const sentinelClaudeSetupToken = 'sk-ant-oat01-SENTINEL-3f9a7c2e5b18d604a7e2c9f4b60d8153';

/// Codex refresh token. Never read by DartClaw, and a far worse loss than the
/// access token it mints, so it is swept for in its own right.
const sentinelCodexRefreshToken = 'rt-SENTINEL-8c1d5e3a9b2f47600ad3e6c8195b7f24';

/// ChatGPT account the sentinel Codex credential belongs to. Not a secret on
/// its own, but it identifies the subscription and rides the same headers.
const sentinelCodexAccountId = 'acct-SENTINEL-2b6f0d8e4a91c357';

/// Codex access token, far enough from expiry that the freshness gate presents
/// it without rotating — a fixture that refreshed mid-sweep would change the
/// value being swept for.
final sentinelCodexAccessToken = sentinelJwt(DateTime.utc(2099));

/// Every subscription credential value a container must never be able to read.
List<String> get subscriptionSentinels => [
  sentinelClaudeSetupToken,
  sentinelCodexAccessToken,
  sentinelCodexRefreshToken,
  sentinelCodexAccountId,
];

/// Builds a structurally valid JWT carrying [exp] as a numeric seconds claim.
///
/// The store reads the expiry out of this payload, and a token it cannot parse
/// reads as *no credential at all* — which would silently turn a conformance
/// fixture into an admission fixture.
String sentinelJwt(DateTime exp) {
  String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
      '.${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': sentinelCodexAccountId})}'
      '.U0VOVElORUwtc2lnbmF0dXJl';
}

/// Opens a dedicated credential store under [dataDir] in the shipped layout.
///
/// Pointed at a fixture `HOME` so the login-collision guard evaluates against
/// the temp directory rather than the developer's own provider logins.
SubscriptionCredentialStore openSentinelCredentialStore(Directory dataDir) {
  final home = Directory(p.join(dataDir.path, 'operator-home'))..createSync(recursive: true);
  return SubscriptionCredentialStore.open(
    credentialsDir: p.join(dataDir.path, 'credentials'),
    environment: {'HOME': home.path},
  );
}

/// Writes the sentinel `setup-token` record through the shipped write path.
void writeSentinelClaudeCredential(SubscriptionCredentialStore store, {DateTime? issuedAt}) =>
    store.storeClaudeSetupToken(sentinelClaudeSetupToken, issuedAt: issuedAt ?? DateTime.now().toUtc());

/// Writes `CODEX_HOME/auth.json` the way the vendor CLI does, and answers the
/// access token it wrote so a caller sweeps for the value actually stored.
///
/// DartClaw has no Codex write path — the vendor owns that file — so the shape
/// is reproduced here rather than routed through the store.
String writeSentinelCodexCredential(
  SubscriptionCredentialStore store, {
  DateTime? expiresAt,
  DateTime? lastRefresh,
  String refreshToken = sentinelCodexRefreshToken,
  String accountId = sentinelCodexAccountId,
}) {
  final accessToken = expiresAt == null ? sentinelCodexAccessToken : sentinelJwt(expiresAt);
  File(store.codexAuthPath).writeAsStringSync(
    jsonEncode({
      'tokens': {'access_token': accessToken, 'refresh_token': refreshToken, 'account_id': accountId},
      'last_refresh': (lastRefresh ?? DateTime.now().toUtc()).toIso8601String(),
    }),
  );
  return accessToken;
}

/// Fails, naming the surface, when any of [sentinels] is readable in [surfaces].
///
/// One shared detector so a suite cannot quietly sweep for a value its own
/// fixture never planted: the self-test in
/// `subscription_sentinel_support_test.dart` proves this call fails on a real
/// leak of every subscription credential shape.
void expectSentinelsAbsent(Map<String, String> surfaces, List<String> sentinels) {
  // The detector enforces its own preconditions: an empty surface map or an
  // empty needle list would sweep nothing and pass, which is the exact failure
  // this shared helper exists to make impossible.
  expect(surfaces, isNotEmpty, reason: 'the sweep was handed no surfaces, so it proves nothing');
  expect(sentinels, isNotEmpty, reason: 'the sweep was handed no sentinels, so it proves nothing');
  surfaces.forEach((name, contents) {
    for (final sentinel in sentinels) {
      expect(contents, isNot(contains(sentinel)), reason: 'a host credential leaked into $name');
    }
  });
}

/// Container-side paths the sentinel greps cover: the tmpfs scratch space, the
/// image user's home (where both vendor CLIs keep their own login state and
/// where the generated-state mount lands), the mounted project, and the
/// read-write artifacts mount an execution writes its durable outputs to.
const sweptContainerPaths = ['/tmp', '/home/dartclaw', '/project', containerArtifactsPath];

/// [sweptContainerPaths] as one `grep -r` argument list.
final sweptContainerPathArgs = sweptContainerPaths.join(' ');

/// Reads every process's argv inside the boundary.
///
/// `docker inspect` reports only PID 1's `sleep infinity`, so a credential
/// handed to a CLI as a command-line flag reaches none of the other swept
/// surfaces. The reading shell's own command line comes back in the output,
/// which is what lets [containerArgvSweepMarker] fail an unreadable `/proc`
/// instead of letting it satisfy an absence assertion.
const containerArgvSweep = r'cat /proc/*/cmdline 2>/dev/null | tr "\0" " "';

/// The literal every [containerArgvSweep] result carries, because the reading
/// shell's own argv is one of the entries it reads.
const containerArgvSweepMarker = '/proc/*/cmdline';

/// Where the grep control is planted: the image runs `--read-only`, so the
/// writable set under [sweptContainerPaths] is the tmpfs, the two host mounts,
/// and the generated-state mount under the image user's home — which is also
/// the only place under that home a leaked credential could be written.
const _grepControlPlantPaths = ['/tmp', '/project', containerArtifactsPath, containerGeneratedStatePath];
const _grepControlMarker = 'dartclaw-grep-control-marker';
const _grepControlFile = '.dartclaw-grep-control';

/// Plants a marker in every writable location under [sweptContainerPaths] and
/// fails unless the in-container grep finds all of them.
///
/// `2>/dev/null || true` turns a missing path, a permission denial, or an image
/// without GNU grep into empty stdout, which satisfies every absence assertion
/// built on it. One control under one path proves nothing about the others, and
/// the login state a leak would land in lives under the home and artifacts
/// mounts rather than under the project.
Future<void> expectGrepReachesSweptPaths(ContainerAuthority authority) async {
  for (final path in _grepControlPlantPaths) {
    final planted = await authority.exec(['sh', '-c', "printf '%s' '$_grepControlMarker' > $path/$_grepControlFile"]);
    expect(planted.exitCode, 0, reason: 'could not plant the grep control in $path: ${planted.stderr}');
  }
  final found = await authority.exec([
    'sh',
    '-c',
    'grep -r "$_grepControlMarker" $sweptContainerPathArgs 2>/dev/null || true',
  ]);
  expect(found.exitCode, 0, reason: 'the control grep could not run: ${found.stderr}');
  for (final path in _grepControlPlantPaths) {
    expect(
      found.stdout.toString(),
      contains('$path/$_grepControlFile'),
      reason: 'the in-container grep never reached $path, so its absences there prove nothing',
    );
  }
}

/// Shipped agent image, built under a suite-local tag by [ensureAgentImage].
const agentProbeImage = 'dartclaw-agent-parity-probe:latest';

/// Minimal image the gateway probes run, built by [ensureGatewayProbeImage].
///
/// Deliberately not the shipped agent image: the gateway boundary depends on
/// the container flags, the read-only bridge mount, and `network:none`, none of
/// which involve the agent tooling.
const gatewayProbeImage = 'dartclaw-gateway-probe:latest';

/// One request the fake upstream received, captured whole.
///
/// Assertions read these rather than a request count: `count_tokens` is
/// allowlisted and retries also increment a counter, so a count alone cannot
/// distinguish a completed round-trip from a retry storm.
final class UpstreamRequest {
  new({required this.method, required this.path, required this.headers, required this.body});

  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;

  /// The request body decoded as a JSON object, or `null` when it is not one.
  Map<String, Object?>? get json {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// One scripted answer the fake upstream serves for a single provider request.
final class UpstreamReply {
  const new({required this.status, required this.contentType, required this.body});

  /// A server-sent-event stream, which is what both providers' turn paths use.
  const new sse(String body) : this(status: 200, contentType: 'text/event-stream', body: body);

  const new json(String body, {int status = 200}) : this(status: status, contentType: 'application/json', body: body);

  final int status;
  final String contentType;
  final String body;
}

/// Stands in for the provider API on the host side of the boundary.
///
/// Binds loopback port 0: `dart test` runs suites as isolates in one OS
/// process, so a fixed port would collide across suites.
final class FakeProviderUpstream {
  new _(this._server);

  final HttpServer _server;
  final _requests = <UpstreamRequest>[];
  final _scripted = <UpstreamReply>[];

  /// Served for every provider request once set, ahead of any script.
  UpstreamReply? _persistentReply;

  /// Served for provider turn requests once the script is exhausted.
  ///
  /// A CLI decides for itself how many round-trips a turn takes, so a fixture
  /// that scripts an exact count would fail on an extra one. Assertions read
  /// the captured requests instead.
  UpstreamReply? defaultTurnReply;

  /// Headers written onto every answer, reproducing an upstream, intermediary,
  /// WAF, or error page that reflects a request header back at the host.
  ///
  /// The gateway→container hop is the only channel entering a `network:none`
  /// container, so this is the direction a host-held credential could be handed
  /// *into* the boundary rather than out of it.
  Map<String, String> responseHeaders = const {};

  /// Called as each request arrives, before its answer is served.
  ///
  /// The only moment a fixture can observe per-turn generated state that the
  /// production lane deletes when the turn ends: the client is mid-turn here,
  /// so whatever it is reading still exists on the host.
  void Function(UpstreamRequest request)? onRequest;

  Uri get uri => Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${_server.port}');

  /// Every request this upstream received, in arrival order.
  List<UpstreamRequest> get requests => List.unmodifiable(_requests);

  int get requestCount => _requests.length;

  Map<String, String> get lastHeaders => _requests.isEmpty ? const {} : _requests.last.headers;

  /// Requests that reached a provider turn path, excluding token counting.
  List<UpstreamRequest> get turnRequests => _requests.where((r) => !r.path.endsWith('/count_tokens')).toList();

  static Future<FakeProviderUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = FakeProviderUpstream._(server);
    server.listen(upstream._serve, onError: (Object _) {});
    return upstream;
  }

  /// Queues [replies] as the answers to the next provider turn requests, in order.
  void script(List<UpstreamReply> replies) => _scripted.addAll(replies);

  /// Answers every provider request with [reply], ignoring any script.
  ///
  /// Failing only the first request proves nothing: clients retry 5xx and would
  /// be served the next queued response.
  void alwaysReply(UpstreamReply reply) => _persistentReply = reply;

  Future<void> _serve(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
    final body = await utf8.decoder.bind(request).join();
    final captured = UpstreamRequest(method: request.method, path: request.uri.path, headers: headers, body: body);
    _requests.add(captured);
    onRequest?.call(captured);

    final reply = _replyFor(request.uri.path);
    request.response.statusCode = reply.status;
    request.response.headers.set(HttpHeaders.contentTypeHeader, reply.contentType);
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    responseHeaders.forEach(request.response.headers.set);
    request.response.write(reply.body);
    await request.response.close();
  }

  UpstreamReply _replyFor(String path) {
    final persistent = _persistentReply;
    if (persistent != null) return persistent;
    // Token counting is allowlisted on the provider surface and the client may
    // call it any number of times; it must never consume a scripted turn.
    if (path.endsWith('/count_tokens')) return const UpstreamReply.json('{"input_tokens":42}');
    if (_scripted.isNotEmpty) return _scripted.removeAt(0);
    // The default keeps the pre-existing gateway probes, which assert on
    // reachability rather than protocol content, working unchanged.
    return defaultTurnReply ?? const UpstreamReply.json('{"ok":true}');
  }

  Future<void> close() => _server.close(force: true);
}

/// Builds an Anthropic Messages SSE turn whose only content is [text].
String anthropicTextTurn(String text, {String messageId = 'msg_fake_text'}) => _anthropicSse(
  messageId: messageId,
  stopReason: 'end_turn',
  blocks: [
    _sseEvent('content_block_start', {
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    }),
    _sseEvent('content_block_delta', {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': text},
    }),
    _sseEvent('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
  ],
);

/// Builds an Anthropic Messages SSE turn that calls [toolName] with [input].
///
/// The input is streamed as `input_json_delta` fragments because that is the
/// only shape the real API uses — a client that accumulates partial JSON would
/// otherwise never be exercised.
String anthropicToolUseTurn({
  required String toolName,
  required Map<String, Object?> input,
  String toolUseId = 'toolu_fake_write',
  String messageId = 'msg_fake_tool',
}) {
  final encoded = jsonEncode(input);
  final midpoint = encoded.length ~/ 2;
  return _anthropicSse(
    messageId: messageId,
    stopReason: 'tool_use',
    blocks: [
      _sseEvent('content_block_start', {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'tool_use', 'id': toolUseId, 'name': toolName, 'input': <String, Object?>{}},
      }),
      for (final fragment in [encoded.substring(0, midpoint), encoded.substring(midpoint)])
        _sseEvent('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'input_json_delta', 'partial_json': fragment},
        }),
      _sseEvent('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
    ],
  );
}

String _anthropicSse({required String messageId, required String stopReason, required List<String> blocks}) => [
  _sseEvent('message_start', {
    'type': 'message_start',
    'message': {
      'id': messageId,
      'type': 'message',
      'role': 'assistant',
      'model': 'claude-fake-upstream',
      'content': <Object?>[],
      'stop_reason': null,
      'stop_sequence': null,
      'usage': {'input_tokens': 12, 'output_tokens': 1},
    },
  }),
  ...blocks,
  _sseEvent('message_delta', {
    'type': 'message_delta',
    'delta': {'stop_reason': stopReason, 'stop_sequence': null},
    'usage': {'output_tokens': 24},
  }),
  _sseEvent('message_stop', {'type': 'message_stop'}),
].join();

/// Builds an OpenAI Responses SSE turn whose only output is the text [text].
String openAiTextTurn(String text, {String responseId = 'resp_fake_text'}) => [
  _sseEvent('response.created', {
    'type': 'response.created',
    'response': _openAiResponse(responseId, status: 'in_progress'),
  }),
  _sseEvent('response.output_item.done', {
    'type': 'response.output_item.done',
    'output_index': 0,
    'item': {
      'type': 'message',
      'id': 'msg_$responseId',
      'role': 'assistant',
      'status': 'completed',
      'content': [
        {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
      ],
    },
  }),
  _sseEvent('response.completed', {
    'type': 'response.completed',
    'response': _openAiResponse(responseId, status: 'completed'),
  }),
].join();

/// Builds an OpenAI Responses SSE turn that calls [name] with [arguments].
String openAiFunctionCallTurn({
  required String name,
  required Map<String, Object?> arguments,
  String callId = 'call_fake_shell',
  String responseId = 'resp_fake_call',
}) => [
  _sseEvent('response.created', {
    'type': 'response.created',
    'response': _openAiResponse(responseId, status: 'in_progress'),
  }),
  _sseEvent('response.output_item.done', {
    'type': 'response.output_item.done',
    'output_index': 0,
    'item': {
      'type': 'function_call',
      'id': 'fc_$callId',
      'call_id': callId,
      'name': name,
      // The wire carries the arguments as a JSON *string*, not a nested object.
      'arguments': jsonEncode(arguments),
      'status': 'completed',
    },
  }),
  _sseEvent('response.completed', {
    'type': 'response.completed',
    'response': _openAiResponse(responseId, status: 'completed'),
  }),
].join();

/// Builds an OpenAI Responses SSE turn that invokes the custom tool [name].
///
/// Codex's code mode advertises a single custom tool whose input is raw source
/// text rather than JSON arguments, and composes its real tools inside it.
String openAiCustomToolCallTurn({
  required String name,
  required String input,
  String callId = 'call_fake_exec',
  String responseId = 'resp_fake_custom',
}) => [
  _sseEvent('response.created', {
    'type': 'response.created',
    'response': _openAiResponse(responseId, status: 'in_progress'),
  }),
  _sseEvent('response.output_item.done', {
    'type': 'response.output_item.done',
    'output_index': 0,
    'item': {'type': 'custom_tool_call', 'id': 'ctc_$callId', 'call_id': callId, 'name': name, 'input': input},
  }),
  _sseEvent('response.completed', {
    'type': 'response.completed',
    'response': _openAiResponse(responseId, status: 'completed'),
  }),
].join();

Map<String, Object?> _openAiResponse(String id, {required String status}) => {
  'id': id,
  'object': 'response',
  'created_at': 1750000000,
  'status': status,
  'model': 'codex-fake-upstream',
  'output': <Object?>[],
  'usage': {
    'input_tokens': 12,
    'input_tokens_details': {'cached_tokens': 0},
    'output_tokens': 24,
    'output_tokens_details': {'reasoning_tokens': 0},
    'total_tokens': 36,
  },
};

String _sseEvent(String event, Map<String, Object?> data) => 'event: $event\ndata: ${jsonEncode(data)}\n\n';

/// One live container authority under test.
final class ContainerAuthority {
  new(this.gateway, this.authority, this.manager);

  final HostGateway gateway;
  final GatewayAuthority authority;
  final ContainerManager manager;

  bool _released = false;

  Future<ProcessResult> exec(List<String> command) =>
      Process.run('docker', ['exec', manager.containerName, ...command]);

  Future<ProcessResult> curl(String url, {String body = ''}) =>
      exec(['curl', '-s', '--max-time', '20', '-X', 'POST', '-H', 'content-type: application/json', '-d', body, url]);

  /// The response *headers* the container reads back off the pipe.
  ///
  /// `-D -` dumps them to stdout and `-o /dev/null` discards the body, so the
  /// assertion is about the one surface the sentinel sweeps never observe: what
  /// the gateway writes *into* the boundary.
  Future<ProcessResult> curlResponseHeaders(String url, {String body = ''}) => exec([
    'curl',
    '-s',
    '-D',
    '-',
    '-o',
    '/dev/null',
    '--max-time',
    '20',
    '-X',
    'POST',
    '-H',
    'content-type: application/json',
    '-d',
    body,
    url,
  ]);

  Future<String> curlStatus(String url, {String body = ''}) async {
    final result = await exec([
      'curl',
      '-s',
      '-o',
      '/dev/null',
      '-w',
      '%{http_code}',
      '--max-time',
      '20',
      '-X',
      'POST',
      '-H',
      'content-type: application/json',
      '-d',
      body,
      url,
    ]);
    return result.stdout.toString().trim();
  }

  Future<Map<String, Object?>> inspect() async {
    final result = await Process.run('docker', ['inspect', manager.containerName]);
    final entries = jsonDecode(result.stdout as String) as List<Object?>;
    return entries.single as Map<String, Object?>;
  }

  Future<void> release() async {
    if (_released) {
      await gateway.revoke(authority);
      return;
    }
    _released = true;
    await gateway.revoke(authority);
    await manager.stop();
  }
}

/// Starts [manager]'s container and binds every surface [principal] requires.
///
/// Registration happens before the container exists so an unusable provider
/// configuration is refused first, which is the production ordering.
Future<ContainerAuthority> startContainerAuthority({
  required HostGateway gateway,
  required ContainerManager manager,
  required GatewayPrincipal principal,
  Set<String> allowedMcpTools = const {},
  Duration readyTimeout = const Duration(seconds: 30),
}) async {
  final authority = gateway.register(principal: principal, allowedMcpTools: allowedMcpTools);
  await manager.start();
  for (final surface in authority.requiredSurfaces) {
    gateway.attach(authority, surface, await manager.startBridge(surface, bridgePortFor(surface)));
  }
  await authority.ready.timeout(readyTimeout);

  final live = ContainerAuthority(gateway, authority, manager);
  addTearDown(live.release);
  return live;
}

Future<bool> dockerAvailable() async {
  try {
    return (await Process.run('docker', ['version'])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Locates the checkout from the resolved package location.
///
/// Deliberately not `git rev-parse`: it depends on the process working
/// directory, which `dart test` shares across parallel suites, and the release
/// gate runs from checkouts exported without a `.git` directory.
Future<String> repoRoot() async {
  final packageUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
  if (packageUri == null) throw StateError('Cannot resolve the dartclaw_runtime package location');
  // .../packages/dartclaw_runtime/lib/dartclaw_runtime.dart
  return p.normalize(p.join(p.dirname(packageUri.toFilePath()), '..', '..', '..'));
}

/// Builds the Linux bridge if this checkout has not produced one yet.
Future<String> ensureBridgeBinary(String repoRoot) async {
  final probe = await Process.run('docker', ['version', '--format', '{{.Server.Arch}}']);
  final architecture = BridgeBinaryProvisioner.architectureFor(probe.stdout as String);
  if (architecture == null) {
    throw StateError('This Docker engine architecture has no shipped bridge binary');
  }
  final path = p.join(repoRoot, 'build', 'bridge', BridgeBinaryProvisioner.fileNameFor(architecture));
  if (!File(path).existsSync()) {
    final built = await Process.run('bash', [p.join(repoRoot, 'dev', 'tools', 'build_bridge.sh')]);
    if (built.exitCode != 0) {
      throw StateError('Failed to cross-compile the container bridge: ${built.stderr}');
    }
  }
  return path;
}

/// Builds the shipped agent image under a suite-local tag.
Future<void> ensureAgentImage(String repoRoot) async {
  final existing = await Process.run('docker', ['image', 'inspect', agentProbeImage]);
  if (existing.exitCode == 0) return;
  final built = await Process.run('docker', ['build', '-t', agentProbeImage, p.join(repoRoot, 'docker')]);
  if (built.exitCode != 0) {
    throw StateError('Failed to build the agent image: ${built.stderr}');
  }
}

/// Builds the minimal probe image the gateway boundary suite runs.
Future<void> ensureGatewayProbeImage() async {
  final existing = await Process.run('docker', ['image', 'inspect', gatewayProbeImage]);
  if (existing.exitCode == 0) return;

  final context = Directory.systemTemp.createTempSync('gateway_probe_image_');
  try {
    File(p.join(context.path, 'Dockerfile')).writeAsStringSync(
      'FROM debian:bookworm-slim\n'
      'RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl '
      '&& rm -rf /var/lib/apt/lists/*\n'
      'RUN groupadd -g 1000 dartclaw && useradd -m -u 1000 -g dartclaw dartclaw\n'
      'USER dartclaw\n'
      'CMD ["sleep", "infinity"]\n',
    );
    final built = await Process.run('docker', ['build', '-t', gatewayProbeImage, context.path]);
    if (built.exitCode != 0) {
      throw StateError('Failed to build the gateway probe image: ${built.stderr}');
    }
  } finally {
    context.deleteSync(recursive: true);
  }
}

Future<bool> containerExists(String name) async {
  final result = await Process.run('docker', ['ps', '-a', '--filter', 'name=^$name\$', '--format', '{{.Names}}']);
  return (result.stdout as String).trim().isNotEmpty;
}

/// Creates a workspace directory the container's own user can write to.
///
/// `ContainerManager` chowns only the generated-state and artifacts dirs;
/// `workspaceMounts` pass through exactly as the host created them, and the
/// image user is uid 1000. A root-run gate on native Linux Docker would
/// otherwise mount a root-owned `/project` and every container-side write would
/// fail `EACCES`, while Docker Desktop's uid remapping hides it.
Future<Directory> createImageOwnedWorkspace(String path) async {
  final workspace = Directory(path)..createSync(recursive: true);
  final chowned = await Process.run('chown', [containerImageUidGid, workspace.path]);
  if (chowned.exitCode != 0) {
    // Docker Desktop remaps uids, so an unprivileged host that cannot chown
    // still runs. A native-Linux gate runs as root and does chown.
    printOnFailure('Could not chown ${workspace.path} to $containerImageUidGid: ${chowned.stderr}');
  }
  return workspace;
}

/// Every regular file under [directory], read as text, keyed by relative path.
///
/// Used to sweep a host-side mount for a planted sentinel: the container writes
/// into it, so its contents are container-authored.
Map<String, String> readAllFiles(Directory directory) {
  if (!directory.existsSync()) return const {};
  final contents = <String, String>{};
  for (final entity in directory.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    try {
      contents[p.relative(entity.path, from: directory.path)] = entity.readAsStringSync();
    } on FileSystemException {
      // A file the host cannot open cannot be asserted on either way.
    } on FormatException {
      // Non-UTF-8 content cannot carry an ASCII sentinel as text.
    }
  }
  return contents;
}

/// The boundary one running container exposes, reduced to the parts a
/// credential mode could change — names and destinations, never host paths or
/// values, which differ per authority for reasons unrelated to the mode.
///
/// Shared so both provider suites compare the same three surfaces: a container
/// being unable to tell which credential mode it runs under is not a
/// per-provider property. Generated state is deliberately *not* here — what
/// counts as a stable generated-state comparison differs per provider, so each
/// suite asserts its own.
final class ContainerSurface {
  new({required this.networkNames, required this.mounts, required this.environmentNames});

  final Set<String> networkNames;

  /// Container-side mount destinations and whether each is writable.
  final Map<String, Object?> mounts;
  final Set<String> environmentNames;

  static Future<ContainerSurface> read(ContainerAuthority authority) async {
    final inspected = await authority.inspect();
    final networks = (inspected['NetworkSettings']! as Map<String, Object?>)['Networks']! as Map<String, Object?>;
    final mounts = (inspected['Mounts']! as List<Object?>).cast<Map<String, Object?>>();
    final environment = await authority.exec(['env']);
    expect(environment.exitCode, 0, reason: 'could not read the container environment: ${environment.stderr}');

    return ContainerSurface(
      networkNames: networks.keys.toSet(),
      mounts: {for (final mount in mounts) mount['Destination']! as String: mount['RW']},
      environmentNames: (environment.stdout as String)
          .split('\n')
          .where((line) => line.contains('='))
          .map((line) => line.split('=').first)
          .toSet(),
    );
  }
}

/// Strips the per-run identifiers the provider CLIs put in their own file names.
///
/// A backup named after its creation time, a session file named after a
/// sequence number, and a per-step home named after a UUID all differ between
/// two authorities for reasons that have nothing to do with the credential
/// mode. Only those identifiers are normalized: a file one mode has and the
/// other does not still fails a set comparison.
String withoutRunIdentifiers(String name) => name
    .replaceAll(RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'), '<id>')
    .replaceAll(RegExp(r'\d+'), '<n>');

/// Drives a `docker exec` to completion and returns its combined output.
Future<String> execOutput(ContainerManager manager, List<String> command) async {
  final process = await manager.exec(command);
  await process.stdin.close();
  final stdout = process.stdout.transform(const SystemEncoding().decoder).join();
  final stderr = process.stderr.transform(const SystemEncoding().decoder).join();
  await process.exitCode;
  return '${await stdout}${await stderr}';
}
