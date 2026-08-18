@Tags(['integration', 'slow'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore, containerCodexExecutable;
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

/// The base path the ChatGPT backend serves under, reproduced on the fake so
/// the host-side path mapping is exercised instead of being assumed.
const _backendBasePath = '/backend-api/codex';

/// Where the scripted turn dumps container process argv.
const _argvFileName = 'mediated-argv-codex.txt';

/// The command the scripted tool call runs: it writes the proof file and, in
/// the same shell, dumps every process's argv.
///
/// The dump is taken from inside the turn on purpose. Argv is a surface no
/// other sweep reaches — `docker inspect` carries only PID 1's `sleep infinity`
/// — and the vendor CLI is a per-turn `docker exec` that has already exited by
/// the time the post-turn sweeps run, so this shell, whose parent *is* that
/// CLI, is the only vantage point its command line exists from.
const _scriptedWrite =
    'printf $_proofContent > /project/$_proofFileName; $containerArgvSweep > /project/$_argvFileName';

/// Every header either credential mode could authenticate with, so a per-mode
/// assertion can bound the set rather than deny one name at a time.
const _credentialHeaders = {'authorization', 'x-api-key', 'openai-api-key', 'api-key'};

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

  /// The dedicated store this run's subscription fixture is read from, so the
  /// test can assert its path is not what the container ends up pointed at.
  SubscriptionCredentialStore? subscriptionStore;

  /// Resolves the dedicated `CODEX_HOME` through the shipped seams: the store
  /// snapshot and `providers.codex.auth: subscription` feed the registry, and
  /// the freshness gate presents whatever the store holds.
  ///
  /// The vendor refresh fails the test rather than running: the fixture token is
  /// far from expiry, so a rotation here would mean the gate misread it — and
  /// would swap the value every later assertion sweeps for.
  ProviderCredentialSource subscriptionCredentialSource() {
    final store = openSentinelCredentialStore(dataDir);
    subscriptionStore = store;
    writeSentinelCodexCredential(store);
    final registry = CredentialRegistry(
      credentials: const CredentialsConfig(),
      env: const {},
      providers: const ProvidersConfig(
        entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
      ),
      subscriptions: store.readAll(),
    );
    return CodexCredentialSource(
      resolve: () => registry.resolve('codex'),
      authority: CodexRefreshAuthority(
        store: store,
        vendorRefresh: (_) async => fail('the fixture credential is fresh, so no rotation should be driven'),
      ),
    );
  }

  Future<_MediatedCodex> assembleMediatedCodex({bool subscription = false}) async {
    final name = 'dartclaw-mediated-codex-${DateTime.now().microsecondsSinceEpoch}';
    final workspace = await createImageOwnedWorkspace(p.join(dataDir.path, 'workspaces', name));
    final generatedStateDir = p.join(dataDir.path, 'containers', name);
    // An execution with an artifacts contract gets this mounted read-write, so
    // the boundary under test is the one a workflow step really runs behind —
    // and the sweep below covers that mount rather than skipping it.
    final artifactsDir = Directory(p.join(dataDir.path, 'artifacts', name))..createSync(recursive: true);

    final gateway = HostGateway(
      providerAdapters: {
        'codex': OpenAiResponsesAdapter(
          credential: subscription
              ? subscriptionCredentialSource()
              : ProviderCredentialSource.apiKey(() => sentinelOpenAiCredential),
          upstream: upstream.uri,
          // The subscription upstream carries a base path, which is what the
          // `/v1/responses` -> `/responses` mapping extends rather than
          // replaces. Reproducing that shape here is the only way the mapping
          // is exercised at all against a local fake.
          subscriptionUpstream: upstream.uri.replace(path: _backendBasePath),
        ),
      },
    );
    final manager = ContainerManager(
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
        openAiFunctionCallTurn(name: 'exec_command', callId: 'call_mediated_write', arguments: {'cmd': _scriptedWrite}),
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

  test('a containerized codex turn on a stored subscription completes credential-free', () async {
    upstream.script([
      UpstreamReply.sse(
        openAiFunctionCallTurn(name: 'exec_command', callId: 'call_mediated_write', arguments: {'cmd': _scriptedWrite}),
      ),
    ]);
    upstream.defaultTurnReply = UpstreamReply.sse(openAiTextTurn('wrote the proof file'));
    final fixture = await assembleMediatedCodex(subscription: true);
    final store = subscriptionStore!;

    final result = await fixture.run(
      'Write the proof file.',
      // Where production points a *host* Codex spawn: the dedicated store's own
      // home. A container run must drop it, so the container never learns even
      // the path the credential lives at.
      providerEnvironment: {'CODEX_HOME': store.codexHome},
    );

    // 1. The turn really ran through the one-shot lane and through the mount.
    expect(result.responseText, isNotEmpty, reason: 'the mediated codex turn produced no assistant text');
    final proof = File(p.join(fixture.workspace.path, _proofFileName));
    expect(proof.existsSync(), isTrue, reason: 'the container-side write never reached the host workspace');
    expect(proof.readAsStringSync(), _proofContent);

    // 2. Every hop reached the backend-mapped path carrying both injected
    //    headers. Asserted per request, and the path set is enumerated so an
    //    unmapped `/v1/responses` slipping through fails rather than passing
    //    an "at least one was right" check.
    expect(upstream.requests, isNotEmpty);
    expect(upstream.turnRequests.map((request) => request.path).toSet(), {'$_backendBasePath/responses'});
    for (final request in upstream.requests) {
      expect(request.headers['authorization'], 'Bearer $sentinelCodexAccessToken');
      expect(request.headers['chatgpt-account-id'], sentinelCodexAccountId);
      expect(request.headers['originator'], OpenAiResponsesAdapter.originator);
      // Enumerated rather than an absence check: exactly one credential-bearing
      // header is presented, so an API-key header smuggled alongside the Bearer
      // fails here even though each header on its own would look correct.
      expect(request.headers.keys.toSet().intersection(_credentialHeaders), {'authorization'});
    }

    // 3. The home the lane generated is under this authority's own state mount
    //    and points at its bridge. Read from the mid-turn snapshot because the
    //    lane deletes the home when the turn ends — and asserted as the exact
    //    file the CLI was reading, not as an absence some unset variable would
    //    also satisfy.
    // One `codex-home-<step id>` directory directly under this authority's own
    // state mount — not a shared or host-side home the lane reached out to.
    final generatedHomeSegments = p.split(fixture.generatedConfigPath);
    expect(generatedHomeSegments, hasLength(2), reason: 'the generated config is not directly inside one home dir');
    expect(generatedHomeSegments.first, startsWith('codex-home'));
    expect(generatedHomeSegments.last, 'config.toml');
    expect(
      fixture.generatedConfig,
      contains('base_url = "${fixture.authority.manager.providerBridgeUrl}/v1"'),
      reason: 'the generated config did not target the provider bridge',
    );

    // 4. And none of the stored values exists on any container-readable surface
    //    — the refresh token and account id included, not only the access token
    //    the requests carried, plus the host path the store lives at, which is
    //    what the dropped provider environment would otherwise have carried in.
    await fixture.expectSentinelUnreadable(
      sentinels: [sentinelCodexAccessToken, sentinelCodexRefreshToken, sentinelCodexAccountId, store.codexHome],
    );
  });

  test('the container surface is the same under subscription auth as under an API key', () async {
    // Codex is the provider whose two modes diverge most host-side — a re-pinned
    // upstream, a mapped path, different headers — and the one that generates a
    // per-step home inside the boundary. If the mode were observable from inside
    // a container anywhere, it would be here.
    upstream.defaultTurnReply = UpstreamReply.sse(openAiTextTurn('mediation reached the upstream'));
    final apiKey = await assembleMediatedCodex();
    expect((await apiKey.run('Reply with a short greeting.')).responseText, isNotEmpty);
    final subscription = await assembleMediatedCodex(subscription: true);
    expect((await subscription.run('Reply with a short greeting.')).responseText, isNotEmpty);

    final surfaces = <String, ContainerSurface>{
      for (final arm in {'api-key': apiKey, 'subscription': subscription}.entries)
        arm.key: await ContainerSurface.read(arm.value.authority),
    };
    final apiKeySurface = surfaces['api-key']!;
    final subscriptionSurface = surfaces['subscription']!;

    for (final entry in surfaces.entries) {
      expect(entry.value.networkNames, {'none'}, reason: '${entry.key} attached a network beyond none');
    }
    expect(subscriptionSurface.mounts, apiKeySurface.mounts);
    expect(subscriptionSurface.environmentNames, apiKeySurface.environmentNames);

    // The generated state is compared through the configuration rather than a
    // file-name set: the vendor CLI writes its own tree (sessions, skills,
    // shell snapshots) as the turn proceeds, so two snapshots taken at the
    // first upstream call differ by CLI progress, not by credential mode. The
    // `config.toml` is the whole of what DartClaw generates for the container,
    // and it is what a mode leaking inward would have to change.
    expect(
      subscription.generatedConfig,
      apiKey.generatedConfig,
      reason: 'the credential mode changed the configuration the container reads',
    );
    expect(apiKeySurface.mounts, isNotEmpty);
    expect(apiKeySurface.environmentNames, isNotEmpty);
    expect(apiKey.generatedConfig, isNotEmpty, reason: 'neither turn generated a config, so this is vacuous');
  });
}

final class _MediatedCodex {
  new(this.authority, this.workspace, this.generatedStateDir);

  final ContainerAuthority authority;
  final Directory workspace;
  final Directory generatedStateDir;

  /// Generated state as it existed while the CLI was mid-turn.
  Map<String, String> generatedStateSnapshot = const {};

  void snapshotGeneratedState() {
    if (generatedStateSnapshot.isEmpty) generatedStateSnapshot = readAllFiles(generatedStateDir);
  }

  /// The `config.toml` the one-shot lane generated for this turn.
  String get generatedConfig => _generatedConfigEntry.value;

  /// Its path relative to this authority's generated-state mount.
  String get generatedConfigPath => _generatedConfigEntry.key;

  MapEntry<String, String> get _generatedConfigEntry => generatedStateSnapshot.entries.firstWhere(
    (entry) => entry.key.endsWith('config.toml'),
    orElse: () => throw StateError('the one-shot lane generated no config.toml: ${generatedStateSnapshot.keys}'),
  );

  Future<WorkflowCliTurnResult> run(String prompt, {Map<String, String>? providerEnvironment}) {
    final request = CliTurnRequest(
      prompt: prompt,
      workingDirectory: workspace.path,
      policy: const ExecutionPolicy.container('workspace'),
      // The host provider environment, planted exactly where production holds
      // the real credential for this mode. The container branch must drop this
      // map wholesale.
      providerConfig: WorkflowCliProviderConfig(
        executable: 'codex',
        environment: providerEnvironment ?? const {'OPENAI_API_KEY': sentinelOpenAiCredential},
      ),
      containerManager: authority.manager,
      // Never called in container mode: the lane must exec through the
      // container, so a host spawn here would be a boundary escape.
      processStarter: (exe, args, {workingDirectory, environment}) =>
          throw StateError('a containerized one-shot must exec through the container, never the host'),
      uuid: const Uuid(),
      log: Logger('mediated-codex-test'),
      stepTimeout: const Duration(minutes: 4),
      // No sandboxOverride: the production lane must itself disable Codex's
      // OS sandbox for containerized runs (the container is the boundary and
      // bubblewrap cannot start under the hardening) — passing it here would
      // mask a regression of that default.
    );
    return CodexCliProvider().run(request);
  }

  /// Fails when any of [sentinels] is readable from inside the boundary.
  Future<void> expectSentinelUnreadable({List<String> sentinels = const [sentinelOpenAiCredential]}) async {
    final containerEnv = await _read(['env'], 'the container environment');
    final processEnviron = await _read(['sh', '-c', 'tr "\\0" "\\n" < /proc/1/environ'], 'PID 1 environ');
    // Container process argv, dumped by the turn itself (see [_scriptedWrite]).
    final argvDump = File(p.join(workspace.path, _argvFileName));
    expect(argvDump.existsSync(), isTrue, reason: 'the scripted turn wrote no argv dump, so argv is unswept');
    final capturedArgv = argvDump.readAsStringSync();
    expect(
      capturedArgv,
      contains(containerCodexExecutable),
      reason: 'the argv dump did not capture the vendor CLI, so its absences prove nothing about the CLI',
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
    // Positive control: a sweep that reads nothing would pass vacuously, and
    // this turn is known to have written the proof file.
    expect(workspaceFiles, isNotEmpty, reason: 'the workspace sweep read no files, so it proves nothing');
    expect(generatedStateSnapshot, isNotEmpty, reason: 'the mid-turn sweep read no files, so it proves nothing');

    final surfaces = <String, String>{
      'container env': containerEnv,
      '/proc/1/environ': processEnviron,
      'container process argv (mid-turn)': capturedArgv,
      sweptContainerPathArgs: scanned.join('\n'),
      'docker inspect': inspect,
      for (final entry in workspaceFiles.entries) 'workspace/${entry.key}': entry.value,
      // Both the state the turn left behind and the state it was actively
      // reading: the generated home is the surface a credential would land on.
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
