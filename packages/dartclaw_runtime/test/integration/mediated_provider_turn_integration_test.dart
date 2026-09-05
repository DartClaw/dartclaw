@Tags(['integration', 'slow'])
@Timeout(Duration(minutes: 10))
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ClaudeCodeHarness, TurnResult, containerClaudeExecutable;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
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

/// Every header either credential mode could authenticate with, so a per-mode
/// assertion can bound the set rather than deny one name at a time.
const _credentialHeaders = {'authorization', 'x-api-key'};

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

  /// Resolves a stored `setup-token` exactly as the deployment's own wiring
  /// does: a dedicated store snapshot plus `providers.claude.auth: subscription`
  /// through the shipped registry, never a hand-built resolution.
  ProviderCredentialSource subscriptionCredentialSource() {
    final store = openSentinelCredentialStore(dataDir);
    writeSentinelClaudeCredential(store);
    final registry = CredentialRegistry(
      credentials: const CredentialsConfig(),
      env: const {},
      providers: const ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription)},
      ),
      subscriptions: store.readAll(),
    );
    return ProviderCredentialSource(() => registry.resolve('claude'));
  }

  /// Assembles one real container authority with a Claude harness bound to it.
  Future<_MediatedClaude> assembleMediatedClaude({bool subscription = false}) async {
    final name = 'dartclaw-mediated-claude-${DateTime.now().microsecondsSinceEpoch}';
    final workspace = await createImageOwnedWorkspace(p.join(dataDir.path, 'workspaces', name));
    final generatedStateDir = p.join(dataDir.path, 'containers', name);
    // An execution with an artifacts contract gets this mounted read-write, so
    // the boundary under test is the one a workflow step really runs behind —
    // and the sweep below covers that mount rather than skipping it.
    final artifactsDir = Directory(p.join(dataDir.path, 'artifacts', name))..createSync(recursive: true);

    final gateway = HostGateway(
      providerAdapters: {
        'claude': AnthropicMessagesAdapter(
          credential: subscription
              ? subscriptionCredentialSource()
              : ProviderCredentialSource.apiKey(() => sentinelAnthropicCredential),
          upstream: upstream.uri,
        ),
      },
    );
    final manager = ContainerManager(
      ownerLabel: ContainerManager.ownerLabel(dataDir.path),
      config: const ContainerConfig(enabled: true, image: agentProbeImage),
      containerName: name,
      profileId: 'workspace',
      workspaceMounts: ['${workspace.path}:/project:rw'],
      generatedStateDir: generatedStateDir,
      artifactsDir: artifactsDir.path,
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
      // Planted exactly where production holds the real host credential for
      // this mode. The sweep below then proves the container spawn *drops* it,
      // rather than proving it was never anywhere to begin with.
      environment: subscription
          ? const {'CLAUDE_CODE_OAUTH_TOKEN': sentinelClaudeSetupToken}
          : const {'ANTHROPIC_API_KEY': sentinelAnthropicCredential},
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
    expect(result.isError, isFalse, reason: 'the turn must complete through mediation alone: $result');
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

    expect(result.isError, isFalse, reason: 'the mediated turn must complete: $result');

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

  test('a containerized claude turn on a stored setup-token completes credential-free', () async {
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
    final fixture = await assembleMediatedClaude(subscription: true);

    final result = await fixture.turn('Write the proof file.');

    expect(result.isError, isFalse, reason: 'the mediated subscription turn must complete: $result');

    // 1. The turn really ran: the container wrote through the mount, and the
    //    scripted tool round-trip came back. Without this the sweep below would
    //    be sweeping a container that never did any provider work.
    final proof = File(p.join(fixture.workspace.path, _proofFileName));
    expect(proof.existsSync(), isTrue, reason: 'the container-side write never reached the host workspace');
    expect(proof.readAsStringSync(), _proofContent);
    expect(fixture.toolResultIds(upstream), contains(_scriptedToolUseId));

    // 2. Every hop to the upstream carries the subscription scheme — the raw
    //    Bearer plus the beta that makes it acceptable — and never the API-key
    //    header. Asserted per request: one correctly-shaped call among several
    //    would still mean the others went out wrong.
    expect(upstream.requests, isNotEmpty);
    for (final request in upstream.requests) {
      expect(request.headers['authorization'], 'Bearer $sentinelClaudeSetupToken');
      expect(
        request.headers['anthropic-beta']?.split(',').map((value) => value.trim()),
        contains(AnthropicMessagesAdapter.oauthBeta),
      );
      // Enumerated rather than an absence check: exactly one credential-bearing
      // header is presented, so an API key riding alongside the Bearer fails
      // here even though each header on its own would look correct.
      expect(request.headers.keys.toSet().intersection(_credentialHeaders), {'authorization'});
    }

    // 3. And the stored token exists on no surface the container can read,
    //    including the state it was reading mid-turn.
    await fixture.expectSentinelUnreadable(sentinels: const [sentinelClaudeSetupToken]);
  });

  test('the container surface is the same under subscription auth as under an API key', () async {
    // Both arms run a real turn: an empty generated-state directory would make
    // the file-name comparison below hold between two containers that never
    // wrote anything, which is the vacuous version of this test.
    upstream.defaultTurnReply = UpstreamReply.sse(anthropicTextTurn('mediation reached the upstream'));
    final apiKey = await assembleMediatedClaude();
    expect((await apiKey.turn('Reply with a short greeting.')).isError, isFalse);
    final subscription = await assembleMediatedClaude(subscription: true);
    expect((await subscription.turn('Reply with a short greeting.')).isError, isFalse);

    final surfaces = <String, ContainerSurface>{
      for (final arm in {'api-key': apiKey, 'subscription': subscription}.entries)
        arm.key: await ContainerSurface.read(arm.value.authority),
    };
    final apiKeySurface = surfaces['api-key']!;
    final subscriptionSurface = surfaces['subscription']!;
    final generatedStateNames = {
      for (final arm in {'api-key': apiKey, 'subscription': subscription}.entries)
        arm.key: readAllFiles(arm.value.generatedStateDir).keys.map(withoutRunIdentifiers).toSet(),
    };

    // 1. `network:none` and nothing else attached, in both modes.
    for (final entry in surfaces.entries) {
      expect(entry.value.networkNames, {'none'}, reason: '${entry.key} attached a network beyond none');
    }

    // 2-4. Each set is enumerated and compared whole: an absence check would
    //      pass for a subscription container that had gained a mount, an
    //      environment variable, or a generated file the API-key one lacks.
    expect(subscriptionSurface.mounts, apiKeySurface.mounts);
    expect(subscriptionSurface.environmentNames, apiKeySurface.environmentNames);
    expect(generatedStateNames['subscription'], generatedStateNames['api-key']);

    // Positive controls: three empty sets would compare equal and prove nothing.
    expect(apiKeySurface.mounts, isNotEmpty);
    expect(apiKeySurface.environmentNames, isNotEmpty);
    expect(generatedStateNames['api-key'], isNotEmpty, reason: 'neither turn generated state, so this is vacuous');
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
    final reportedSuccess = turnOutcome is TurnResult && !turnOutcome.isError;
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

  Future<TurnResult> turn(String message) => harness.turn(
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

  /// Fails when any of [sentinels] is readable from inside the boundary.
  ///
  /// The generated-state mount is swept host-side because it is the CLI's
  /// `CLAUDE_CONFIG_DIR` — whatever the client persisted there during the turn
  /// is exactly what a later container process could read back.
  Future<void> expectSentinelUnreadable({List<String> sentinels = const [sentinelAnthropicCredential]}) async {
    final containerEnv = await _read(['env'], 'the container environment');
    final processEnviron = await _read(['sh', '-c', 'tr "\\0" "\\n" < /proc/1/environ'], 'PID 1 environ');
    // The CLI is still running here — it is stopped in teardown — so this dump
    // carries its own command line, the surface `docker inspect` cannot show
    // because it reports only PID 1's `sleep infinity`.
    final processArgv = await _read(['sh', '-c', containerArgvSweep], 'container process argv');
    expect(
      processArgv,
      contains(containerArgvSweepMarker),
      reason: 'the argv sweep did not read even its own command line, so its absences prove nothing',
    );
    expect(
      processArgv,
      contains(containerClaudeExecutable),
      reason: 'the argv sweep did not capture the running CLI, so its absences prove nothing about the CLI',
    );
    // `grep -r`, never `-l`: the list form prints only file *paths*, so a
    // sentinel-absence assertion over it could never fail. One pattern per
    // sentinel, because a leak of any one of them is a leak.
    final scanned = <String>[];
    for (final sentinel in sentinels) {
      scanned.add(
        await _read(['sh', '-c', 'grep -r "$sentinel" $sweptContainerPathArgs 2>/dev/null || true'], 'the swept paths'),
      );
    }
    // Positive controls for the grep itself: a marker planted under every
    // writable swept path proves it reaches all of them, and the proof file
    // proves it also reads what the turn itself wrote.
    await expectGrepReachesSweptPaths(authority);
    expect(
      await _read([
        'sh',
        '-c',
        'grep -r "$_proofContent" $sweptContainerPathArgs 2>/dev/null || true',
      ], 'the swept paths'),
      contains(_proofContent),
      reason: 'the in-container grep found nothing it should have found, so its absences prove nothing',
    );
    final inspect = jsonEncode(await authority.inspect());

    final workspaceFiles = readAllFiles(workspace);
    // Positive controls: a sweep that reads nothing would pass vacuously, and
    // this turn is known to have written the proof file and to have been
    // mid-turn when the snapshot was taken.
    expect(workspaceFiles, isNotEmpty, reason: 'the workspace sweep read no files, so it proves nothing');
    expect(generatedStateSnapshot, isNotEmpty, reason: 'the mid-turn sweep read no files, so it proves nothing');

    final surfaces = <String, String>{
      'container env': containerEnv,
      '/proc/1/environ': processEnviron,
      'container process argv': processArgv,
      sweptContainerPathArgs: scanned.join('\n'),
      'docker inspect': inspect,
      for (final entry in workspaceFiles.entries) 'workspace/${entry.key}': entry.value,
      for (final entry in readAllFiles(generatedStateDir).entries) 'generated-state/${entry.key}': entry.value,
      for (final entry in generatedStateSnapshot.entries) 'generated-state (mid-turn)/${entry.key}': entry.value,
    };

    expectSentinelsAbsent(surfaces, sentinels);
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
