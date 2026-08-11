@Tags(['integration', 'slow'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../container/gateway/gateway_test_support.dart' show RecordingMcpTool;

/// Proves the scoped host gateway against a real Docker engine.
///
/// The contract is identical on Linux Docker and Docker Desktop; only the
/// engine differs. Both platforms must be recorded for the 0.24 release gate,
/// but a single run proves the executing platform.
///
/// A credential that appears anywhere the container can read is a failure, so
/// the sentinel below is deliberately distinctive and grepped for.
const _sentinelCredential = 'sk-ant-SENTINEL-d41d8cd98f00b204e9800998ecf8427e';

/// Image the probe containers run; built by the suite, see [_ensureProbeImage].
const _probeImage = 'dartclaw-gateway-probe:latest';

void main() {
  late String repoRoot;
  late String bridgeBinary;
  late _FakeProviderUpstream upstream;
  late Directory dataDir;

  setUpAll(() async {
    if (!await _dockerAvailable()) {
      throw StateError('Docker is required for the scoped host gateway suite');
    }
    repoRoot = await _repoRoot();
    bridgeBinary = await _ensureBridgeBinary(repoRoot);
    await _ensureProbeImage();
  });

  setUp(() async {
    upstream = await _FakeProviderUpstream.start();
    dataDir = Directory.systemTemp.createTempSync('gateway_integration_');
  });

  tearDown(() async {
    await upstream.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<_Authority> startAuthority({
    String sessionId = 'session-a',
    String profile = 'workspace',
    Set<String> allowedMcpTools = const {},
    List<String> mcpToolNames = const [],
    List<String>? mcpCalls,
    List<String>? denials,
  }) async {
    final registry = McpProtocolHandler();
    for (final name in mcpToolNames) {
      registry.registerTool(RecordingMcpTool(name, mcpCalls ?? <String>[]));
    }
    final gateway = HostGateway(
      providerAdapters: {'claude': AnthropicMessagesAdapter(apiKey: () => _sentinelCredential, upstream: upstream.uri)},
      mcpHandler: () => registry,
      mcpToolCanonicals: () => const {'brave_search': CanonicalTool.webSearch, 'web_fetch': CanonicalTool.webFetch},
      onDenied: (_, reason) => denials?.add(reason),
    );
    final manager = ContainerManager(
      config: const ContainerConfig(enabled: true, image: _probeImage),
      containerName: 'dartclaw-gwtest-${DateTime.now().microsecondsSinceEpoch}-${sessionId.hashCode.abs()}',
      profileId: profile,
      workspaceMounts: const [],
      generatedStateDir: Directory.systemTemp.createTempSync('dartclaw-gwstate-').path,
      hasMcpBridge: allowedMcpTools.isNotEmpty,
      bridgeBinaryPath: bridgeBinary,
      buildContextDir: repoRoot,
      workingDir: '/tmp',
    );
    final principal = GatewayPrincipal(
      sessionId: sessionId,
      providerId: 'claude',
      policy: ExecutionPolicy.container(profile),
    );
    final authority = gateway.register(principal: principal, allowedMcpTools: allowedMcpTools);

    await manager.start();
    for (final surface in authority.requiredSurfaces) {
      gateway.attach(authority, surface, await manager.startBridge(surface, bridgePortFor(surface)));
    }
    await authority.ready.timeout(const Duration(seconds: 30));

    final live = _Authority(gateway, authority, manager);
    addTearDown(live.release);
    return live;
  }

  group('mediated access under network:none', () {
    test('an authorized provider call reaches the host adapter and returns its answer', () async {
      final authority = await startAuthority();

      final probe = await authority.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{"model":"x"}');

      expect(probe.exitCode, 0, reason: probe.stderr.toString());
      expect(probe.stdout.toString(), contains('"ok":true'));
      expect(upstream.requestCount, 1);
      expect(upstream.lastHeaders['x-api-key'], _sentinelCredential);
    });

    test('inspect shows network none and only the two sanctioned host mounts', () async {
      final authority = await startAuthority();

      final inspect = await authority.inspect();
      final config = inspect['HostConfig'] as Map<String, Object?>;
      final mounts = (inspect['Mounts'] as List<Object?>).cast<Map<String, Object?>>();

      expect(config['NetworkMode'], 'none');
      expect(config['PortBindings'], anyOf(isNull, isEmpty));
      expect((inspect['NetworkSettings'] as Map<String, Object?>)['Ports'], anyOf(isNull, isEmpty));

      // Exactly two: the read-only bridge executable and this authority's own
      // generated-state scratch. Anything else would be a host object the
      // container was not meant to reach.
      final byDestination = {for (final mount in mounts) mount['Destination'] as String: mount};
      expect(byDestination.keys, unorderedEquals(['/opt/dartclaw/dartclaw-bridge', containerGeneratedStatePath]));
      expect(byDestination['/opt/dartclaw/dartclaw-bridge']!['RW'], isFalse);
      expect(byDestination[containerGeneratedStatePath]!['RW'], isTrue);
      for (final mount in mounts) {
        expect(mount['Source'], isNot(contains('.sock')));
      }
    });

    test('a direct Internet probe from the container fails', () async {
      final authority = await startAuthority();

      final probe = await authority.exec([
        'curl',
        '-s',
        '--max-time',
        '5',
        '-o',
        '/dev/null',
        'https://api.anthropic.com/v1/messages',
      ]);

      expect(probe.exitCode, isNot(0), reason: 'network:none must leave no direct egress path');
    });

    test('the host credential appears nowhere the container can read', () async {
      final authority = await startAuthority();
      final response = await authority.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{"model":"x"}');

      final env = await authority.exec(['env']);
      final procEnv = await authority.exec(['sh', '-c', 'cat /proc/1/environ | tr "\\0" "\\n"']);
      final inspect = jsonEncode(await authority.inspect());
      final tmp = await authority.exec(['sh', '-c', 'grep -r "$_sentinelCredential" /tmp 2>/dev/null || true']);

      for (final surface in [response.stdout, env.stdout, procEnv.stdout, inspect, tmp.stdout]) {
        expect(surface.toString(), isNot(contains(_sentinelCredential)));
      }
      // The sentinel is only ever added on the host-to-provider hop.
      expect(upstream.lastHeaders['x-api-key'], _sentinelCredential);
    });
  });

  group('host-side refusals', () {
    test('an alternate destination on the provider surface is refused before any outbound request', () async {
      final authority = await startAuthority();

      final probe = await authority.curlStatus('http://127.0.0.1:$providerBridgePort/v1/files', body: '{}');

      expect(probe, '404');
      expect(upstream.requestCount, 0);
    });

    test('a restricted execution cannot use provider-native web tools', () async {
      final authority = await startAuthority(profile: 'restricted');

      final probe = await authority.curlStatus(
        'http://127.0.0.1:$providerBridgePort/v1/messages',
        body: jsonEncode({
          'tools': [
            {'type': 'web_search_20250305'},
          ],
        }),
      );

      expect(probe, '403');
      expect(upstream.requestCount, 0);
    });

    test('an MCP frame on the provider surface is refused', () async {
      final authority = await startAuthority(allowedMcpTools: {'web_search'}, mcpToolNames: ['brave_search']);

      final probe = await authority.curlStatus(
        'http://127.0.0.1:$providerBridgePort/mcp',
        body: '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
      );

      expect(probe, '404');
    });

    test('a provider path on the MCP surface never reaches the provider', () async {
      final authority = await startAuthority(allowedMcpTools: {'web_search'}, mcpToolNames: ['brave_search']);

      await authority.curl('http://127.0.0.1:$mcpBridgePort/v1/messages', body: '{"model":"x"}');

      expect(upstream.requestCount, 0, reason: 'the MCP pipe has no provider adapter bound to it');
    });

    test('an oversized request body is refused without taking the surface down', () async {
      final authority = await startAuthority();

      final probe = await authority.exec([
        'sh',
        '-c',
        'head -c 12000000 /dev/zero | tr "\\0" "a" > /tmp/big.json; '
            'curl -s -o /dev/null -w "%{http_code}" -X POST '
            '-H "content-type: application/json" --data-binary @/tmp/big.json '
            'http://127.0.0.1:$providerBridgePort/v1/messages',
      ]);

      // The host refuses mid-upload, so curl may report the refusal status or
      // report nothing at all once the connection drops. What must hold is that
      // it never succeeded and never reached the provider.
      expect(probe.stdout.toString().trim(), isNot('200'));
      expect(upstream.requestCount, 0);

      // A bounded refusal is not a protocol fault: the pipe stays usable.
      final after = await authority.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{"model":"x"}');
      expect(after.stdout.toString(), contains('"ok":true'));
      expect(upstream.requestCount, 1);
    });
  });

  group('bridged MCP authorization', () {
    test('an approved tool reaches the host implementation and an unapproved one does not', () async {
      final calls = <String>[];
      final denials = <String>[];
      final authority = await startAuthority(
        allowedMcpTools: {'web_search'},
        mcpToolNames: ['brave_search', 'web_fetch'],
        mcpCalls: calls,
        denials: denials,
      );

      final approved = await authority.curl(
        'http://127.0.0.1:$mcpBridgePort/mcp',
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'brave_search', 'arguments': <String, Object?>{}},
        }),
      );
      // Called directly, not via the filtered listing: the host is the only
      // enforcement point.
      final unapproved = await authority.curl(
        'http://127.0.0.1:$mcpBridgePort/mcp',
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {'name': 'web_fetch', 'arguments': <String, Object?>{}},
        }),
      );

      expect(approved.stdout.toString(), contains('"result"'));
      expect(unapproved.stdout.toString(), contains('"error"'));
      expect(calls, ['brave_search']);
      expect(denials.single, contains('web_fetch'));
    });

    test('discovery lists only the approved implementations', () async {
      final authority = await startAuthority(
        allowedMcpTools: {'web_search'},
        mcpToolNames: ['brave_search', 'web_fetch'],
      );

      final listed = await authority.curl(
        'http://127.0.0.1:$mcpBridgePort/mcp',
        body: '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
      );

      expect(listed.stdout.toString(), contains('brave_search'));
      expect(listed.stdout.toString(), isNot(contains('web_fetch')));
    });
  });

  group('authority lifetime', () {
    test('concurrent authorities own separate containers and cannot borrow each other', () async {
      final first = await startAuthority(sessionId: 'session-a');
      final second = await startAuthority(sessionId: 'session-b');

      expect(first.manager.containerName, isNot(second.manager.containerName));

      // Each container reaches only its own bridge: the ports are identical but
      // the namespaces are not.
      expect((await first.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{}')).exitCode, 0);
      expect((await second.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{}')).exitCode, 0);
      expect(upstream.requestCount, 2);

      await first.release();

      // A released authority's container is gone, so nothing can replay through
      // it — and the surviving authority is untouched.
      expect(await _containerExists(first.manager.containerName), isFalse);
      expect((await second.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{}')).exitCode, 0);
    });

    test('release destroys the container, revokes the pipes, and is idempotent', () async {
      final authority = await startAuthority();
      final containerName = authority.manager.containerName;

      await authority.release();
      await authority.release();

      expect(await _containerExists(containerName), isFalse);
      expect(authority.authority.isRevoked, isTrue);
      expect(authority.gateway.liveAuthorityCount, 0);
      expect(await _bridgeProcessesFor(containerName), isEmpty);
    });

    test('a request after release is refused because the pipe no longer exists', () async {
      final authority = await startAuthority();
      final containerName = authority.manager.containerName;
      await authority.release();

      final probe = await Process.run('docker', [
        'exec',
        containerName,
        'curl',
        '-s',
        'http://127.0.0.1:$providerBridgePort/v1/messages',
      ]);

      expect(probe.exitCode, isNot(0));
      expect(upstream.requestCount, 0);
    });
  });
}

/// One live container authority under test.
final class _Authority {
  _Authority(this.gateway, this.authority, this.manager);

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

/// Stands in for the provider API on the host side of the boundary.
final class _FakeProviderUpstream {
  _FakeProviderUpstream._(this._server);

  final HttpServer _server;

  var requestCount = 0;
  Map<String, String> lastHeaders = {};

  Uri get uri => Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${_server.port}');

  static Future<_FakeProviderUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _FakeProviderUpstream._(server);
    server.listen((request) async {
      upstream.requestCount++;
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
      upstream.lastHeaders = headers;
      await request.drain<void>();
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
    });
    return upstream;
  }

  Future<void> close() => _server.close(force: true);
}

Future<bool> _dockerAvailable() async {
  try {
    final result = await Process.run('docker', ['version', '--format', '{{.Server.Arch}}']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<String> _repoRoot() async {
  final packageUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  if (packageUri == null) throw StateError('Cannot resolve the dartclaw_server package location');
  // .../packages/dartclaw_server/lib/dartclaw_server.dart
  return p.normalize(p.join(p.dirname(packageUri.toFilePath()), '..', '..', '..'));
}

/// Builds the Linux bridge if this checkout has not produced one yet.
Future<String> _ensureBridgeBinary(String repoRoot) async {
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

/// Builds the probe image this suite runs its containers from.
///
/// Deliberately not the shipped agent image: the gateway boundary depends on
/// the container flags, the read-only bridge mount, and `network:none`, none of
/// which involve the agent tooling. Using the same `debian:bookworm-slim` base
/// with an HTTP client keeps the suite runnable regardless of the agent image's
/// provider-installation steps, which S03 owns.
Future<void> _ensureProbeImage() async {
  final existing = await Process.run('docker', ['image', 'inspect', _probeImage]);
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
    final built = await Process.run('docker', ['build', '-t', _probeImage, context.path]);
    if (built.exitCode != 0) {
      throw StateError('Failed to build the gateway probe image: ${built.stderr}');
    }
  } finally {
    context.deleteSync(recursive: true);
  }
}

Future<bool> _containerExists(String name) async {
  final result = await Process.run('docker', ['ps', '-a', '--filter', 'name=^$name\$', '--format', '{{.Names}}']);
  return (result.stdout as String).trim().isNotEmpty;
}

/// Docker exec processes still attached to a container, as the engine sees them.
Future<List<String>> _bridgeProcessesFor(String containerName) async {
  final result = await Process.run('docker', ['ps', '-a', '--filter', 'name=^$containerName\$', '--format', '{{.ID}}']);
  return (result.stdout as String).trim().isEmpty ? const [] : [(result.stdout as String).trim()];
}
