import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void _git(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
}

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during runtime composition test');
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

DartclawConfig _config(
  String dataDir, {
  GatewayConfig gateway = const GatewayConfig(authMode: 'none'),
  TurnLimitsConfig turnLimits = const TurnLimitsConfig.defaults(),
}) => DartclawConfig(
  agent: const AgentConfig(provider: 'claude'),
  credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
  providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)}),
  gateway: gateway,
  governance: GovernanceConfig(turnLimits: turnLimits),
  scheduling: const SchedulingConfig(heartbeatEnabled: true),
  server: ServerConfig(dataDir: dataDir, claudeExecutable: Platform.resolvedExecutable),
);

/// The composition-root contract a caller outside the CLI app depends on:
/// what `headless` omits, what it must still carry, and what `shutdown()` owns.
void main() {
  late Directory tempDir;
  late File configFile;
  late LogService logService;
  late MessageRedactor messageRedactor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_runtime_composition_');
    configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');
    messageRedactor = MessageRedactor();
    logService = LogService.fromConfig(
      format: 'human',
      level: 'WARNING',
      redactor: LogRedactor(redactor: messageRedactor),
    );
  });

  tearDown(() async {
    await logService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<DartclawRuntime> build({
    bool headless = false,
    String? runtimeCwd,
    GatewayConfig gateway = const GatewayConfig(authMode: 'none'),
    TurnLimitsConfig turnLimits = const TurnLimitsConfig.defaults(),
  }) => DartclawRuntime.build(
    _config(tempDir.path, gateway: gateway, turnLimits: turnLimits),
    dataDir: tempDir.path,
    port: 3000,
    harnessFactory: _harnessFactoryFor(FakeAgentHarness()),
    searchDbFactory: (_) => sqlite3.openInMemory(),
    taskDbFactory: (_) => sqlite3.openInMemory(),
    stderrLine: (_) {},
    exitFn: _unexpectedExit,
    resolvedConfigPath: configFile.path,
    messageRedactor: messageRedactor,
    resolvedAssets: const ResolvedAssets.embedded(),
    headless: headless,
    runtimeCwd: runtimeCwd,
    runWorkflowSkillsBootstrap: false,
  );

  Future<HeadlessRuntimeStaging> stage() => DartclawRuntime.stageHeadless(
    _config(tempDir.path),
    dataDir: tempDir.path,
    harnessFactory: _harnessFactoryFor(FakeAgentHarness()),
    searchDbFactory: (_) => sqlite3.openInMemory(),
    taskDbFactory: (_) => sqlite3.openInMemory(),
    stderrLine: (_) {},
    exitFn: _unexpectedExit,
    runtimeCwd: tempDir.path,
    runWorkflowSkillsBootstrap: false,
    providerAuthPreflight: FakeProviderAuthPreflight(),
  );

  test('a headless build omits every ingress and scheduled surface', () async {
    final runtime = await build(headless: true);
    addTearDown(runtime.shutdown);

    expect(runtime.server, isNull, reason: 'no HTTP routes, web UI or server-hosted MCP endpoint');
    expect(runtime.channelManager, isNull);
    expect(runtime.scheduleService, isNull, reason: 'no schedule service means no heartbeat either');
    expect(runtime.tokenService, isNull);
  });

  test('a headless build keeps the full guarded execution and workflow stack', () async {
    final runtime = await build(headless: true);
    addTearDown(runtime.shutdown);

    expect(runtime.harness, isNotNull);
    expect(runtime.executions, isNotNull);
    expect(runtime.workflowRegistry, isNotNull);
    expect(runtime.workflowService, isNotNull);
    expect(runtime.taskService, isNotNull);
    expect(runtime.kvService, isNotNull);
    expect(runtime.agentExecutionRepository, isNotNull);
    expect(runtime.projectService, isNotNull);
  });

  test('a headless build mints no gateway token and advertises no MCP endpoint', () async {
    // `authMode` defaults to `token`, so this is the shape a headless embedder
    // gets without opting out of auth: a secret written to the data directory
    // and every harness pointed at an endpoint nothing serves.
    final runtime = await build(headless: true, gateway: const GatewayConfig());
    addTearDown(runtime.shutdown);

    expect(runtime.tokenService, isNull);
    expect(
      File(p.join(tempDir.path, 'gateway_token')).existsSync(),
      isFalse,
      reason: 'no surface serves the token, so nothing may persist one',
    );
  });

  test('the default build carries the server, and server is non-null exactly when headless is false', () async {
    final runtime = await build();
    addTearDown(runtime.shutdown);

    expect(runtime.server, isNotNull);
    expect(runtime.scheduleService, isNotNull);
  });

  test('production composition gives the manager and primary runner the configured turn limits', () async {
    const limits = TurnLimitsConfig(stallTimeout: Duration(seconds: 17), turnTimeout: Duration(seconds: 41));
    final runtime = await build(turnLimits: limits);
    addTearDown(runtime.shutdown);

    expect(runtime.server!.turns.turnLimits, limits);
    expect(runtime.requireExecutions.primary!.turnLimits, limits);
  });

  test('a headless workflow composition drives no primary lane and only its scoped providers', () async {
    // The zero-server lane provisions worker runners only. A primary harness
    // would spawn a vendor CLI the run never uses, and an unreferenced provider
    // could let a logged-out one block a run that does not touch it.
    final staging = await stage();
    final runtime = await staging.completeForExecution({'claude'});
    addTearDown(runtime.shutdown);

    expect(runtime.harness, isNull);
    expect(runtime.requireExecutions.primary, isNull);
    expect(runtime.requireExecutions.snapshot.providers.keys, {'claude'});
    expect(runtime.taskExecutor, isNotNull);
  });

  test('a lifecycle-only composition can mutate run state and nothing else', () async {
    // cancel/pause only transition persisted state, so nothing that could
    // dispatch a step may exist: no capacity, no executor, and
    // no turn seam for an agent step to reach.
    final staging = await stage();
    final runtime = await staging.completeForLifecycle();
    addTearDown(runtime.shutdown);

    expect(runtime.workflowService, isNotNull);
    expect(runtime.taskService, isNotNull);
    expect(runtime.harness, isNull);
    expect(runtime.taskExecutor, isNull);

    // The security and harness layers are not composed at all, rather than
    // composed with empty capacity. That is what keeps a `cancel` from running
    // ACP validation subprocesses or touching the container runtime because of
    // a misconfiguration the verb has no use for.
    expect(runtime.executions, isNull);
    expect(runtime.resetService, isNull);
    expect(runtime.selfImprovement, isNull);
    expect(runtime.containerAuthorities, isNull);

    // And reading one refuses by name instead of throwing a bare null error.
    expect(
      () => runtime.requireExecutions,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('executions'), contains('lifecycle-only')),
        ),
      ),
    );
  });

  test('the coordinator serves a workflow execution with a real worker in headless composition', () async {
    final staging = await stage();
    final runtime = await staging.completeForExecution({'claude'});
    addTearDown(runtime.shutdown);

    final lease = await runtime.requireExecutions.acquire(
      const ExecutionRequest(
        sessionId: 'workflow-session',
        providerId: 'claude',
        surface: ExecutionSurface.workflow,
        policy: ExecutionPolicy.host(),
      ),
    );
    expect(lease, isNotNull);
    expect(lease!.runner, isNotNull);
    expect(lease.runner.harness.state, WorkerState.idle);
    await lease.release();
  });

  test('a headless embedder keeps the managed-workspace posture and sweeps no repository', () async {
    // `stageHeadless` is the zero-server door; `build(headless: true)` is the
    // embedder's. Only the former force-removes worktrees and deletes branches
    // at teardown, and it does that to the repository it was pointed at — so an
    // embedder pointed at a repository must find it untouched afterwards.
    final repoDir = Directory(p.join(tempDir.path, 'embedder-repo'))..createSync(recursive: true);
    _git(repoDir.path, ['init', '-b', 'main']);
    _git(repoDir.path, ['config', 'user.name', 'Test User']);
    _git(repoDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('hello\n');
    _git(repoDir.path, ['add', 'README.md']);
    _git(repoDir.path, ['commit', '-m', 'initial']);
    // The name the sweep derives from the run id, so a sweep that ran would
    // delete exactly this branch.
    _git(repoDir.path, ['branch', 'dartclaw/workflow/embedderrun']);

    final runtime = await build(headless: true, runtimeCwd: repoDir.path);
    // The sweep only looks at tasks carrying a workflow run id, so give it one.
    await runtime.taskService.create(
      id: 'embedder-task',
      title: 'Workflow step',
      description: 'Workflow step',
      configJson: const {'needsWorktree': true},
      workflowRunId: 'embedderrun',
    );

    await runtime.shutdown();

    final branches = Process.runSync('git', ['branch', '--list'], workingDirectory: repoDir.path).stdout as String;
    expect(branches, contains('dartclaw/workflow/embedderrun'), reason: 'an embedder build must delete no branch');
  });

  test('a completion that fails leaves the staging owning teardown', () async {
    // Between "a completion started" and "a runtime exists" nobody else can
    // close the databases: the caller's `finally` only has the staging.
    final searchDbs = <Database>[];
    final taskDbs = <Database>[];
    final staging = await DartclawRuntime.stageHeadless(
      _config(tempDir.path),
      dataDir: tempDir.path,
      harnessFactory: _harnessFactoryFor(FakeAgentHarness()),
      searchDbFactory: (_) {
        final db = sqlite3.openInMemory();
        searchDbs.add(db);
        return db;
      },
      taskDbFactory: (_) {
        final db = sqlite3.openInMemory();
        taskDbs.add(db);
        return db;
      },
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      runtimeCwd: tempDir.path,
      runWorkflowSkillsBootstrap: false,
      providerAuthPreflight: FakeProviderAuthPreflight(),
    );

    await expectLater(
      staging.completeForExecution({'not-configured'}),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('not-configured'))),
    );
    await staging.dispose();

    expect(
      () => searchDbs.single.select('SELECT 1'),
      throwsA(isA<StateError>()),
      reason: 'the search database was left open',
    );
    expect(
      () => taskDbs.single.select('SELECT 1'),
      throwsA(isA<StateError>()),
      reason: 'the task database was left open',
    );
  });

  test('shutdown stops the scheduled lane and closes the search database last', () async {
    final runtime = await build();

    await runtime.shutdown();

    expect(
      () => runtime.searchDb.select('SELECT 1'),
      throwsA(isA<StateError>()),
      reason: 'the search database is the last thing shutdown closes',
    );
    // Every post-server disposal step is best-effort: a second shutdown drives
    // each one against an already-disposed service, so anything that rethrew
    // instead of logging would surface here.
    await expectLater(runtime.shutdown(), completes);
  });
}
