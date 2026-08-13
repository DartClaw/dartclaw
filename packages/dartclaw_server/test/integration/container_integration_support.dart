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

import 'package:dartclaw_core/dartclaw_core.dart' show containerImageUidGid;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Host credential the Anthropic-facing suites plant and then grep for.
///
/// A credential that appears anywhere the container can read is a failure, so
/// the sentinels are deliberately distinctive.
const sentinelAnthropicCredential = 'sk-ant-SENTINEL-d41d8cd98f00b204e9800998ecf8427e';

/// Host credential the OpenAI-facing suites plant and then grep for.
const sentinelOpenAiCredential = 'sk-openai-SENTINEL-9e107d9d372bb6826bd81d3542a419d6';

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
  UpstreamRequest({required this.method, required this.path, required this.headers, required this.body});

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
  const UpstreamReply({required this.status, required this.contentType, required this.body});

  /// A server-sent-event stream, which is what both providers' turn paths use.
  const UpstreamReply.sse(String body) : this(status: 200, contentType: 'text/event-stream', body: body);

  const UpstreamReply.json(String body, {int status = 200})
    : this(status: status, contentType: 'application/json', body: body);

  final int status;
  final String contentType;
  final String body;
}

/// Stands in for the provider API on the host side of the boundary.
///
/// Binds loopback port 0: `dart test` runs suites as isolates in one OS
/// process, so a fixed port would collide across suites.
final class FakeProviderUpstream {
  FakeProviderUpstream._(this._server);

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
  ContainerAuthority(this.gateway, this.authority, this.manager);

  final HostGateway gateway;
  final GatewayAuthority authority;
  final ContainerManager manager;

  bool _released = false;

  Future<ProcessResult> exec(List<String> command) =>
      Process.run('docker', ['exec', manager.containerName, ...command]);

  Future<ProcessResult> curl(String url, {String body = ''}) =>
      exec(['curl', '-s', '--max-time', '20', '-X', 'POST', '-H', 'content-type: application/json', '-d', body, url]);

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
  final packageUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  if (packageUri == null) throw StateError('Cannot resolve the dartclaw_server package location');
  // .../packages/dartclaw_server/lib/dartclaw_server.dart
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

/// Drives a `docker exec` to completion and returns its combined output.
Future<String> execOutput(ContainerManager manager, List<String> command) async {
  final process = await manager.exec(command);
  await process.stdin.close();
  final stdout = process.stdout.transform(const SystemEncoding().decoder).join();
  final stderr = process.stderr.transform(const SystemEncoding().decoder).join();
  await process.exitCode;
  return '${await stdout}${await stderr}';
}
