@Tags(['integration', 'slow'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/task/codex_cli_provider.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'container_integration_support.dart';

/// Proves a real containerized Codex turn completes through host mediation.
///
/// Codex reaches the upstream through a generated auth-clean home the one-shot
/// lane builds for itself, so this suite asserts the generated configuration as
/// the CLI was actually reading it — mid-turn — rather than supplying a home and
/// asserting its own input back.
const _proofFileName = 'mediated-proof-codex.txt';
const _proofContent = 'mediated-write-ok-codex';

void main() {
  late String checkoutRoot;
  late String bridgeBinary;
  late FakeProviderUpstream upstream;
  late Directory dataDir;

  setUpAll(() async {
    if (!await dockerAvailable()) {
      throw StateError('Docker is required for the mediated codex turn suite');
    }
    checkoutRoot = await repoRoot();
    bridgeBinary = await ensureBridgeBinary(checkoutRoot);
    await ensureAgentImage(checkoutRoot);
  });

  setUp(() async {
    upstream = await FakeProviderUpstream.start();
    dataDir = Directory.systemTemp.createTempSync('mediated_codex_');
  });

  tearDown(() async {
    await upstream.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<_MediatedCodex> assembleMediatedCodex() async {
    final name = 'dartclaw-mediated-codex-${DateTime.now().microsecondsSinceEpoch}';
    final workspace = await createImageOwnedWorkspace(p.join(dataDir.path, 'workspaces', name));
    final generatedStateDir = p.join(dataDir.path, 'containers', name);

    final gateway = HostGateway(
      providerAdapters: {
        'codex': OpenAiResponsesAdapter(apiKey: () => sentinelOpenAiCredential, upstream: upstream.uri),
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
        sessionId: 'mediated-codex',
        providerId: 'codex',
        policy: ExecutionPolicy.container('workspace'),
      ),
    );
    final fixture = _MediatedCodex(authority, workspace, Directory(generatedStateDir));
    // The one-shot lane deletes the generated home when the turn ends, so the
    // only moment its configuration can be observed is while the CLI is using
    // it — which is exactly when the upstream is being called.
    upstream.onRequest = (_) => fixture.snapshotGeneratedState();
    return fixture;
  }

  test('a containerized codex turn writes into the mounted workspace through its auth-clean home', () async {
    upstream.script([
      UpstreamReply.sse(
        openAiFunctionCallTurn(
          name: 'exec_command',
          callId: 'call_mediated_write',
          arguments: {'cmd': 'printf $_proofContent > /project/$_proofFileName'},
        ),
      ),
    ]);
    upstream.defaultTurnReply = UpstreamReply.sse(openAiTextTurn('wrote the proof file'));
    final fixture = await assembleMediatedCodex();

    final result = await fixture.run('Write the proof file.');

    // 1. The turn completed through the one-shot lane.
    expect(result.responseText, isNotEmpty, reason: 'the mediated codex turn produced no assistant text');

    // 2. The home the lane generated pointed the CLI at this authority's bridge.
    expect(
      fixture.generatedConfig,
      allOf(
        contains('base_url = "${fixture.authority.manager.providerBridgeUrl}/v1"'),
        contains('requires_openai_auth = false'),
      ),
      reason: 'the generated config did not target the provider bridge',
    );

    // 3. The container really wrote through the mount, observed host-side.
    final proof = File(p.join(fixture.workspace.path, _proofFileName));
    expect(proof.existsSync(), isTrue, reason: 'the container-side write never reached the host workspace');
    expect(proof.readAsStringSync(), _proofContent);

    // 4. The sentinel is applied on the host-to-upstream hop, in this
    //    provider's own scheme, on every request.
    expect(upstream.requests, isNotEmpty);
    for (final request in upstream.requests) {
      expect(request.headers['authorization'], 'Bearer $sentinelOpenAiCredential');
    }

    // 5. And it exists on no surface the container can read.
    await fixture.expectSentinelUnreadable();
  });
}

final class _MediatedCodex {
  _MediatedCodex(this.authority, this.workspace, this.generatedStateDir);

  final ContainerAuthority authority;
  final Directory workspace;
  final Directory generatedStateDir;

  /// Generated state as it existed while the CLI was mid-turn.
  Map<String, String> generatedStateSnapshot = const {};

  void snapshotGeneratedState() {
    if (generatedStateSnapshot.isEmpty) generatedStateSnapshot = readAllFiles(generatedStateDir);
  }

  /// The `config.toml` the one-shot lane generated for this turn.
  String get generatedConfig => generatedStateSnapshot.entries
      .firstWhere(
        (entry) => entry.key.endsWith('config.toml'),
        orElse: () => throw StateError('the one-shot lane generated no config.toml: ${generatedStateSnapshot.keys}'),
      )
      .value;

  Future<WorkflowCliTurnResult> run(String prompt) {
    final request = CliTurnRequest(
      prompt: prompt,
      workingDirectory: workspace.path,
      policy: const ExecutionPolicy.container('workspace'),
      // The host provider environment, planted exactly where production holds
      // the real key. The container branch must drop this map wholesale.
      providerConfig: const WorkflowCliProviderConfig(
        executable: 'codex',
        environment: {'OPENAI_API_KEY': sentinelOpenAiCredential},
      ),
      containerManager: authority.manager,
      // Never called in container mode: the lane must exec through the
      // container, so a host spawn here would be a boundary escape.
      processStarter: (exe, args, {workingDirectory, environment}) =>
          throw StateError('a containerized one-shot must exec through the container, never the host'),
      uuid: const Uuid(),
      log: Logger('mediated-codex-test'),
      stepTimeout: const Duration(minutes: 4),
      // Load-bearing, not incidental: without an explicit sandbox the lane
      // sends `--full-auto`, and Codex's own Linux sandbox then demands
      // bubblewrap, which the image does not ship and which cannot run under
      // the container's `--cap-drop ALL` / `no-new-privileges` hardening. Every
      // tool call panics. The container is already the isolation boundary. See
      // the FIS's Implementation Observations.
      sandboxOverride: 'danger-full-access',
    );
    return CodexCliProvider().run(request);
  }

  /// Fails when the host credential is readable from inside the boundary.
  Future<void> expectSentinelUnreadable() async {
    final containerEnv = await _read(['env'], 'the container environment');
    final processEnviron = await _read(['sh', '-c', 'tr "\\0" "\\n" < /proc/1/environ'], 'PID 1 environ');
    // `grep -r`, never `-l`: the list form prints only file *paths*, so a
    // sentinel-absence assertion over it could never fail.
    final tmp = await _read(['sh', '-c', 'grep -r "$sentinelOpenAiCredential" /tmp 2>/dev/null || true'], '/tmp');
    final inspect = jsonEncode(await authority.inspect());

    final workspaceFiles = readAllFiles(workspace);
    // Positive control: a sweep that reads nothing would pass vacuously, and
    // this turn is known to have written the proof file.
    expect(workspaceFiles, isNotEmpty, reason: 'the workspace sweep read no files, so it proves nothing');
    expect(generatedStateSnapshot, isNotEmpty, reason: 'the mid-turn sweep read no files, so it proves nothing');

    final surfaces = <String, String>{
      'container env': containerEnv,
      '/proc/1/environ': processEnviron,
      '/tmp': tmp,
      'docker inspect': inspect,
      for (final entry in workspaceFiles.entries) 'workspace/${entry.key}': entry.value,
      // Both the state the turn left behind and the state it was actively
      // reading: the generated home is the surface a credential would land on.
      for (final entry in readAllFiles(generatedStateDir).entries) 'generated-state/${entry.key}': entry.value,
      for (final entry in generatedStateSnapshot.entries) 'generated-state (mid-turn)/${entry.key}': entry.value,
    };

    surfaces.forEach((name, contents) {
      expect(contents, isNot(contains(sentinelOpenAiCredential)), reason: 'the host credential leaked into $name');
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
