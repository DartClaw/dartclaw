@Tags(['integration', 'slow'])
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

import '../container/gateway/gateway_test_support.dart' show RecordingMcpTool;
import 'container_integration_support.dart';

/// Proves the scoped host gateway against a real Docker engine.
///
/// The contract is identical on Linux Docker and Docker Desktop; only the
/// engine differs. Both platforms must be recorded for the 0.24 release gate,
/// but a single run proves the executing platform.
void main() {
  late String checkoutRoot;
  late String bridgeBinary;
  late FakeProviderUpstream upstream;
  late Directory dataDir;

  setUpAll(() async {
    if (!await dockerAvailable()) {
      throw StateError('Docker is required for the scoped host gateway suite');
    }
    checkoutRoot = await repoRoot();
    bridgeBinary = await ensureBridgeBinary(checkoutRoot);
    await ensureGatewayProbeImage();
  });

  setUp(() async {
    upstream = await FakeProviderUpstream.start();
    dataDir = Directory.systemTemp.createTempSync('gateway_integration_');
  });

  tearDown(() async {
    await upstream.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<ContainerAuthority> startAuthority({
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
      providerAdapters: {
        'claude': AnthropicMessagesAdapter(
          credential: ProviderCredentialSource.apiKey(() => sentinelAnthropicCredential),
          upstream: upstream.uri,
        ),
      },
      mcpHandler: () => registry,
      mcpToolCanonicals: () => const {'brave_search': CanonicalTool.webSearch, 'web_fetch': CanonicalTool.webFetch},
      onDenied: (_, reason) => denials?.add(reason),
    );
    final manager = ContainerManager(
      ownerLabel: ContainerManager.ownerLabel(dataDir.path),
      config: const ContainerConfig(enabled: true, image: gatewayProbeImage),
      containerName: 'dartclaw-gwtest-${DateTime.now().microsecondsSinceEpoch}-${sessionId.hashCode.abs()}',
      profileId: profile,
      workspaceMounts: const [],
      generatedStateDir: Directory.systemTemp.createTempSync('dartclaw-gwstate-').path,
      hasMcpBridge: allowedMcpTools.isNotEmpty,
      bridgeBinaryPath: bridgeBinary,
      buildContextDir: checkoutRoot,
      workingDir: '/tmp',
    );
    return startContainerAuthority(
      gateway: gateway,
      manager: manager,
      principal: GatewayPrincipal(
        sessionId: sessionId,
        providerId: 'claude',
        policy: ExecutionPolicy.container(profile),
      ),
      allowedMcpTools: allowedMcpTools,
    );
  }

  group('mediated access under network:none', () {
    test('an authorized provider call reaches the host adapter and returns its answer', () async {
      final authority = await startAuthority();

      final probe = await authority.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{"model":"x"}');

      expect(probe.exitCode, 0, reason: probe.stderr.toString());
      expect(probe.stdout.toString(), contains('"ok":true'));
      expect(upstream.requestCount, 1);
      expect(upstream.lastHeaders['x-api-key'], sentinelAnthropicCredential);
    });

    test('a credential reflected in an upstream response header never reaches the container', () async {
      // Every other assertion in this gate covers what *leaves* the host. The
      // pipe's return path is the only channel entering a `network:none`
      // container, so an upstream, intermediary, WAF, or error page echoing the
      // request `Authorization` back is the one way a host-held credential can
      // be handed into the boundary — and it is read here from inside it.
      upstream.responseHeaders = {
        'authorization': 'Bearer $sentinelAnthropicCredential',
        'x-api-key': sentinelAnthropicCredential,
        'proxy-authenticate': 'Basic realm="$sentinelAnthropicCredential"',
        'set-cookie': 'session=$sentinelAnthropicCredential',
        'x-request-id': 'req-return-path-control',
      };
      final authority = await startAuthority();

      final probe = await authority.curlResponseHeaders(
        'http://127.0.0.1:$providerBridgePort/v1/messages',
        body: '{"model":"x"}',
      );

      expect(probe.exitCode, 0, reason: probe.stderr.toString());
      final received = probe.stdout.toString();
      // Two positive controls: the container really read a header block off the
      // pipe, and the host really presented the credential upstream — without
      // both, the absence assertion below would pass on an empty exchange.
      expect(received, contains('req-return-path-control'), reason: 'no response headers crossed, so this is vacuous');
      expect(upstream.lastHeaders['x-api-key'], sentinelAnthropicCredential);
      expectSentinelsAbsent({'gateway response headers': received}, const [sentinelAnthropicCredential]);
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
      final tmp = await authority.exec(['sh', '-c', 'grep -r "$sentinelAnthropicCredential" /tmp 2>/dev/null || true']);

      for (final surface in [response.stdout, env.stdout, procEnv.stdout, inspect, tmp.stdout]) {
        expect(surface.toString(), isNot(contains(sentinelAnthropicCredential)));
      }
      // The sentinel is only ever added on the host-to-provider hop.
      expect(upstream.lastHeaders['x-api-key'], sentinelAnthropicCredential);
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
      expect(await containerExists(first.manager.containerName), isFalse);
      expect((await second.curl('http://127.0.0.1:$providerBridgePort/v1/messages', body: '{}')).exitCode, 0);
    });

    test('release destroys the container, revokes the pipes, and is idempotent', () async {
      final authority = await startAuthority();
      final containerName = authority.manager.containerName;

      await authority.release();
      await authority.release();

      expect(await containerExists(containerName), isFalse);
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

/// Docker exec processes still attached to a container, as the engine sees them.
Future<List<String>> _bridgeProcessesFor(String containerName) async {
  final result = await Process.run('docker', ['ps', '-a', '--filter', 'name=^$containerName\$', '--format', '{{.ID}}']);
  return (result.stdout as String).trim().isEmpty ? const [] : [(result.stdout as String).trim()];
}
