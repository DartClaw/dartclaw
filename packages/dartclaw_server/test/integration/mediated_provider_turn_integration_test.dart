@Tags(['integration', 'slow'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ClaudeCodeHarness;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'container_integration_support.dart';

/// Proves a real containerized Claude turn completes through host mediation.
///
/// The rest of the release gate proves a container can *read* host-staged
/// state. What this suite adds is the turn itself: the packaged CLI is spawned
/// by the production spawn path, reaches a scripted upstream only through the
/// framed provider-bridge pipe, and the file it writes is observed on the host
/// in the mounted workspace. Configuration labels are not evidence — every
/// assertion observes the running container, the host filesystem, or the
/// requests the upstream really received.
///
/// The suite timeout covers the cold path: image build, container start, bridge
/// handshake, CLI initialization, and two provider round-trips.
const _proofFileName = 'mediated-proof.txt';
const _proofContent = 'mediated-write-ok';
const _scriptedToolUseId = 'toolu_mediated_write';

void main() {
  late String checkoutRoot;
  late String bridgeBinary;
  late FakeProviderUpstream upstream;
  late Directory dataDir;

  setUpAll(() async {
    if (!await dockerAvailable()) {
      throw StateError('Docker is required for the mediated provider turn suite');
    }
    checkoutRoot = await repoRoot();
    bridgeBinary = await ensureBridgeBinary(checkoutRoot);
    await ensureAgentImage(checkoutRoot);
  });

  setUp(() async {
    upstream = await FakeProviderUpstream.start();
    dataDir = Directory.systemTemp.createTempSync('mediated_turn_');
  });

  tearDown(() async {
    await upstream.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  /// Assembles one real container authority with a Claude harness bound to it.
  Future<_MediatedClaude> assembleMediatedClaude() async {
    final name = 'dartclaw-mediated-claude-${DateTime.now().microsecondsSinceEpoch}';
    final workspace = await createImageOwnedWorkspace(p.join(dataDir.path, 'workspaces', name));
    final generatedStateDir = p.join(dataDir.path, 'containers', name);

    final gateway = HostGateway(
      providerAdapters: {
        'claude': AnthropicMessagesAdapter(apiKey: () => sentinelAnthropicCredential, upstream: upstream.uri),
      },
    );
    final manager = ContainerManager(
      config: const ContainerConfig(enabled: true, image: agentProbeImage),
      containerName: name,
      profileId: 'workspace',
      workspaceMounts: ['${workspace.path}:/project:rw'],
      generatedStateDir: generatedStateDir,
      bridgeBinaryPath: bridgeBinary,
      buildContextDir: checkoutRoot,
      workingDir: '/project',
    );
    final authority = await startContainerAuthority(
      gateway: gateway,
      manager: manager,
      principal: const GatewayPrincipal(
        sessionId: 'mediated-claude',
        providerId: 'claude',
        policy: ExecutionPolicy.container('workspace'),
      ),
    );

    // The production spawn path: no host environment reaches the harness, so
    // the container gets the placeholder key and the loopback bridge only.
    final harness = ClaudeCodeHarness(
      cwd: workspace.path,
      containerManager: manager,
      // Planted exactly where production holds the real host key. The sweep
      // below then proves the container spawn *drops* it, rather than proving
      // it was never anywhere to begin with.
      environment: const {'ANTHROPIC_API_KEY': sentinelAnthropicCredential},
      initializeTimeout: const Duration(seconds: 90),
      turnTimeout: const Duration(minutes: 4),
    );
    addTearDown(() async {
      try {
        await harness.stop();
      } catch (_) {} // Teardown is best-effort; the assertions already ran.
    });
    final fixture = _MediatedClaude(authority, harness, workspace, Directory(generatedStateDir));
    // The generated home is the surface a credential would land on, and it is
    // destroyed with the container, so it is also swept while the CLI is
    // mid-turn — the only moment "during the turn" can be observed.
    upstream.onRequest = (_) => fixture.snapshotGeneratedState();
    // Pre-started exactly like production (CLI primary harness and coordinator
    // workers call `start()` before any turn): the spawn must translate the
    // host cwd into the container, or this dies with exit 127.
    await harness.start();
    return fixture;
  }

  test('a scripted provider turn completes inside the hardened image', () async {
    upstream.script([UpstreamReply.sse(anthropicTextTurn('mediation reached the upstream'))]);
    final fixture = await assembleMediatedClaude();

    final result = await fixture.turn('Reply with a short greeting.');

    // The narrowest possible claim, kept separate so a tool-execution failure
    // cannot be mistaken for a broken mediation transport.
    expect(result['is_error'], isFalse, reason: 'the turn must complete through mediation alone: $result');
    expect(upstream.turnRequests, isNotEmpty, reason: 'the turn never reached the mediated upstream');
    expect(upstream.turnRequests.single.json?['stream'], isTrue);
  });

  test('a containerized claude turn writes into the mounted workspace through host mediation', () async {
    upstream.script([
      UpstreamReply.sse(
        anthropicToolUseTurn(
          toolName: 'Write',
          toolUseId: _scriptedToolUseId,
          input: {'file_path': '/project/$_proofFileName', 'content': _proofContent},
        ),
      ),
    ]);
    upstream.defaultTurnReply = UpstreamReply.sse(anthropicTextTurn('wrote the proof file'));
    final fixture = await assembleMediatedClaude();

    final result = await fixture.turn('Write the proof file.');

    expect(result['is_error'], isFalse, reason: 'the mediated turn must complete: $result');

    // 1. The container really wrote through the mount, observed host-side.
    final proof = File(p.join(fixture.workspace.path, _proofFileName));
    expect(proof.existsSync(), isTrue, reason: 'the container-side write never reached the host workspace');
    expect(proof.readAsStringSync(), _proofContent);

    // 2. The tool round-trip really happened. A request count is not evidence:
    //    `count_tokens` is allowlisted and retries also count, so the proof is
    //    a later request carrying the tool_result for the scripted tool_use.
    expect(
      fixture.toolResultIds(upstream),
      contains(_scriptedToolUseId),
      reason: 'no follow-up request returned the scripted tool_use result',
    );

    // 3. The sentinel is applied on the host-to-upstream hop, every time.
    expect(upstream.requests, isNotEmpty);
    for (final request in upstream.requests) {
      expect(request.headers['x-api-key'], sentinelAnthropicCredential);
    }

    // 4. And it exists on no surface the container can read.
    await fixture.expectSentinelUnreadable();
  });

  test('an upstream failure mid-turn surfaces as a failed turn, never a silent success', () async {
    // Every request fails: a single 5xx proves nothing, since the CLI retries
    // and would simply be served the next queued response.
    upstream.alwaysReply(
      const UpstreamReply.json(
        '{"type":"error","error":{"type":"api_error","message":"upstream is down"}}',
        status: 500,
      ),
    );
    final fixture = await assembleMediatedClaude();

    Object? turnOutcome;
    try {
      turnOutcome = await fixture.turn('Write the proof file.');
    } catch (error) {
      turnOutcome = error;
    }

    // A fabricated success is the failure mode under test: either the harness
    // throws, or it returns a result that says the turn errored.
    final reportedSuccess = turnOutcome is Map<String, dynamic> && turnOutcome['is_error'] == false;
    expect(reportedSuccess, isFalse, reason: 'a dead upstream must never produce a successful turn: $turnOutcome');

    // The failure must have happened *at* mediation, not before reaching it.
    expect(upstream.turnRequests, isNotEmpty, reason: 'the turn never reached mediation, so this proves nothing');
    expect(upstream.requests.first.headers['x-api-key'], sentinelAnthropicCredential);

    expect(File(p.join(fixture.workspace.path, _proofFileName)).existsSync(), isFalse);

    // Releasing the authority still destroys the container and its state.
    final containerName = fixture.authority.manager.containerName;
    await fixture.authority.release();
    expect(await containerExists(containerName), isFalse);
    expect(fixture.generatedStateDir.existsSync(), isFalse);
    expect(fixture.authority.authority.isRevoked, isTrue);
  });
}

/// One assembled mediated-Claude fixture: authority, harness, and its mounts.
final class _MediatedClaude {
  new(this.authority, this.harness, this.workspace, this.generatedStateDir);

  final ContainerAuthority authority;
  final ClaudeCodeHarness harness;
  final Directory workspace;
  final Directory generatedStateDir;

  Future<Map<String, dynamic>> turn(String message) => harness.turn(
    sessionId: 'session-mediated',
    messages: [
      {'role': 'user', 'content': message},
    ],
    systemPrompt: '',
    directory: workspace.path,
  );

  /// `tool_use_id`s the client returned results for, across every request.
  Set<String> toolResultIds(FakeProviderUpstream upstream) {
    final ids = <String>{};
    for (final request in upstream.turnRequests) {
      final messages = request.json?['messages'];
      if (messages is! List) continue;
      for (final message in messages) {
        final content = message is Map ? message['content'] : null;
        if (content is! List) continue;
        for (final block in content) {
          if (block is Map && block['type'] == 'tool_result' && block['tool_use_id'] is String) {
            ids.add(block['tool_use_id'] as String);
          }
        }
      }
    }
    return ids;
  }

  /// Generated state as it existed while the CLI was mid-turn.
  Map<String, String> generatedStateSnapshot = const {};

  void snapshotGeneratedState() {
    if (generatedStateSnapshot.isEmpty) generatedStateSnapshot = readAllFiles(generatedStateDir);
  }

  /// Fails when the host credential is readable from inside the boundary.
  ///
  /// The generated-state mount is swept host-side because it is the CLI's
  /// `CLAUDE_CONFIG_DIR` — whatever the client persisted there during the turn
  /// is exactly what a later container process could read back.
  Future<void> expectSentinelUnreadable() async {
    final containerEnv = await _read(['env'], 'the container environment');
    final processEnviron = await _read(['sh', '-c', 'tr "\\0" "\\n" < /proc/1/environ'], 'PID 1 environ');
    // `grep -r`, never `-l`: the list form prints only file *paths*, so a
    // sentinel-absence assertion over it could never fail.
    final tmp = await _read(['sh', '-c', 'grep -r "$sentinelAnthropicCredential" /tmp 2>/dev/null || true'], '/tmp');
    final inspect = jsonEncode(await authority.inspect());

    final workspaceFiles = readAllFiles(workspace);
    // Positive control: a sweep that reads nothing would pass vacuously, and
    // this turn is known to have written the proof file.
    expect(workspaceFiles, isNotEmpty, reason: 'the workspace sweep read no files, so it proves nothing');

    final surfaces = <String, String>{
      'container env': containerEnv,
      '/proc/1/environ': processEnviron,
      '/tmp': tmp,
      'docker inspect': inspect,
      for (final entry in workspaceFiles.entries) 'workspace/${entry.key}': entry.value,
      for (final entry in readAllFiles(generatedStateDir).entries) 'generated-state/${entry.key}': entry.value,
      for (final entry in generatedStateSnapshot.entries) 'generated-state (mid-turn)/${entry.key}': entry.value,
    };

    surfaces.forEach((name, contents) {
      expect(contents, isNot(contains(sentinelAnthropicCredential)), reason: 'the host credential leaked into $name');
    });
  }

  /// Reads a container surface, failing loudly when it cannot be read at all.
  ///
  /// A dead container returns empty stdout, which would otherwise satisfy every
  /// absence assertion below it.
  Future<String> _read(List<String> command, String label) async {
    final result = await authority.exec(command);
    expect(result.exitCode, 0, reason: 'could not read $label: ${result.stderr}');
    return result.stdout.toString();
  }
}
