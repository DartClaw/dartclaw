import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_security/dartclaw_security.dart' show GuardConfig;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowStepOutputTransformer;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

typedef E2EProjectSetup = FutureOr<void> Function(String projectDir);

String _fixturesRoot() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'test', 'fixtures'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'test', 'fixtures'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return Directory(candidate).resolveSymbolicLinksSync();
      }
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow test fixtures');
    }
    current = parent;
  }
}

void _copyDirectorySync(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relativePath = p.relative(entity.path, from: source.path);
    if (entity is File) {
      final destination = File(p.join(target.path, relativePath));
      destination.parent.createSync(recursive: true);
      entity.copySync(destination.path);
    } else if (entity is Directory) {
      Directory(p.join(target.path, relativePath)).createSync(recursive: true);
    }
  }
}

final class E2EFixture {
  final String fixtureProfile;
  final String projectId;
  final String projectRemote;
  final bool useLocalProjectPath;
  final String projectBranch;
  final String? projectCredentials;
  final bool projectDefault;
  final int port;
  final String provider;
  final String workflowModel;
  final String plannerModel;
  final String executorModel;
  final String reviewerModel;
  final int poolSize;
  final String sandbox;
  final bool guardsEnabled;
  final int dailyTokenBudget;
  final bool loopDetectionEnabled;
  final String loggingLevel;
  final bool threadBindingEnabled;
  final String taskCompletionAction;
  final bool workspaceGitSyncEnabled;
  final bool workspaceGitSyncPushEnabled;
  final E2EProjectSetup? projectSetup;

  const E2EFixture({
    this.fixtureProfile = 'workflow-e2e-profile',
    this.projectId = 'workflow-test-todo-app',
    this.projectRemote = 'git@github.com:DartClaw/workflow-test-todo-app.git',
    this.useLocalProjectPath = false,
    this.projectBranch = 'main',
    this.projectCredentials = 'github-main',
    this.projectDefault = true,
    this.port = 3333,
    this.provider = 'codex',
    this.workflowModel = 'gpt-5.4',
    this.plannerModel = 'gpt-5.4',
    this.executorModel = 'gpt-5.3-codex',
    this.reviewerModel = 'gpt-5.3-codex',
    this.poolSize = 3,
    this.sandbox = 'danger-full-access',
    this.guardsEnabled = true,
    this.dailyTokenBudget = 5000000,
    this.loopDetectionEnabled = true,
    this.loggingLevel = 'FINE',
    this.threadBindingEnabled = true,
    this.taskCompletionAction = 'accept',
    this.workspaceGitSyncEnabled = false,
    this.workspaceGitSyncPushEnabled = true,
    this.projectSetup,
  });

  E2EFixture withFixtureProfile(String value) => _copy(fixtureProfile: value);

  E2EFixture withProject(
    String value, {
    String? remote,
    bool? localPath,
    String? branch,
    Object? credentials = _unset,
    bool? isDefault,
  }) => _copy(
    projectId: value,
    projectRemote: remote ?? projectRemote,
    useLocalProjectPath: localPath ?? useLocalProjectPath,
    projectBranch: branch ?? projectBranch,
    projectCredentials: credentials,
    projectDefault: isDefault ?? projectDefault,
  );

  E2EFixture withProjectSetup(E2EProjectSetup setup) => _copy(projectSetup: setup);

  E2EFixture withPoolSize(int value) => _copy(poolSize: value);

  E2EFixture withTaskCompletionAction(String value) => _copy(taskCompletionAction: value);

  E2EFixture withLoggingLevel(String value) => _copy(loggingLevel: value);

  E2EFixture withThreadBinding(bool value) => _copy(threadBindingEnabled: value);

  E2EFixture withProvider({
    required String value,
    required String workflowModel,
    String? plannerModel,
    String? executorModel,
    String? reviewerModel,
    String? sandbox,
  }) => _copy(
    provider: value,
    workflowModel: workflowModel,
    plannerModel: plannerModel ?? this.plannerModel,
    executorModel: executorModel ?? this.executorModel,
    reviewerModel: reviewerModel ?? this.reviewerModel,
    sandbox: sandbox ?? this.sandbox,
  );

  Future<E2EFixtureInstance> build() async {
    final fixturesRoot = _fixturesRoot();
    final profileDir = p.join(fixturesRoot, fixtureProfile);
    if (!Directory(profileDir).existsSync()) {
      throw StateError('Fixture profile does not exist: $profileDir');
    }

    final runtimeDir = Directory.systemTemp.createTempSync('dartclaw_workflow_fixture_');
    final dataDir = p.join(runtimeDir.path, 'data');
    final workspaceDir = p.join(dataDir, 'workspace');
    final workflowWorkspaceDir = p.join(dataDir, 'workflow-workspace');
    final projectDir = p.join(dataDir, 'projects', projectId);

    _copyDirectorySync(Directory(p.join(profileDir, 'workspace')), Directory(workspaceDir));
    _copyDirectorySync(Directory(p.join(profileDir, 'workflow-workspace')), Directory(workflowWorkspaceDir));
    Directory(p.dirname(projectDir)).createSync(recursive: true);

    if (projectSetup != null) {
      await Future.sync(() => projectSetup!(projectDir));
    } else {
      Directory(projectDir).createSync(recursive: true);
    }

    final credentials = <String, CredentialEntry>{
      ...?switch (projectCredentials) {
        final String credential => {
          credential: const CredentialEntry.githubToken(
            token: '',
            repository: 'DartClaw/workflow-test-todo-app',
            envVars: ['GITHUB_TOKEN'],
          ),
        },
        null => null,
      },
    };

    final config = DartclawConfig(
      server: ServerConfig(port: port, dataDir: dataDir, maxParallelTurns: poolSize),
      agent: AgentConfig(provider: provider, model: workflowModel),
      gateway: const GatewayConfig(authMode: 'token'),
      providers: ProvidersConfig(
        entries: {
          provider: ProviderEntry(
            executable: provider,
            poolSize: poolSize,
            options: {
              'approval': 'never',
              'sandbox': sandbox,
            },
          ),
        },
      ),
      credentials: CredentialsConfig(entries: credentials),
      workflow: WorkflowConfig(
        workspaceDir: workflowWorkspaceDir,
        defaults: WorkflowRoleDefaultsConfig(
          workflow: WorkflowRoleModelConfig(provider: provider, model: workflowModel),
          planner: WorkflowRoleModelConfig(provider: provider, model: plannerModel),
          executor: WorkflowRoleModelConfig(provider: provider, model: executorModel),
          reviewer: WorkflowRoleModelConfig(provider: provider, model: reviewerModel),
        ),
      ),
      projects: ProjectConfig(
        definitions: {
          projectId: ProjectDefinition(
            id: projectId,
            remote: useLocalProjectPath ? null : projectRemote,
            localPath: useLocalProjectPath ? projectDir : null,
            branch: projectBranch,
            credentials: projectCredentials,
            cloneStrategy: CloneStrategy.shallow,
            pr: const PrConfig(strategy: PrStrategy.githubPr, draft: true, labels: ['workflow-test']),
            isDefault: projectDefault,
          ),
        },
      ),
      workspace: WorkspaceConfig(
        gitSyncEnabled: workspaceGitSyncEnabled,
        gitSyncPushEnabled: workspaceGitSyncPushEnabled,
      ),
      logging: LoggingConfig(level: loggingLevel),
      governance: GovernanceConfig(
        budget: BudgetConfig(dailyTokens: dailyTokenBudget),
        loopDetection: LoopDetectionConfig(enabled: loopDetectionEnabled),
      ),
      tasks: TaskConfig(completionAction: taskCompletionAction),
      security: SecurityConfig(guards: GuardConfig(enabled: guardsEnabled)),
      features: FeaturesConfig(threadBinding: ThreadBindingFeatureConfig(enabled: threadBindingEnabled)),
    );

    return E2EFixtureInstance._(
      runtimeDir: runtimeDir,
      dataDir: dataDir,
      workspaceDir: workspaceDir,
      workflowWorkspaceDir: workflowWorkspaceDir,
      projectDir: projectDir,
      fixtureProfileDir: profileDir,
      config: config,
    );
  }

  E2EFixture _copy({
    String? fixtureProfile,
    String? projectId,
    String? projectRemote,
    bool? useLocalProjectPath,
    String? projectBranch,
    Object? projectCredentials = _unset,
    bool? projectDefault,
    int? port,
    String? provider,
    String? workflowModel,
    String? plannerModel,
    String? executorModel,
    String? reviewerModel,
    int? poolSize,
    String? sandbox,
    bool? guardsEnabled,
    int? dailyTokenBudget,
    bool? loopDetectionEnabled,
    String? loggingLevel,
    bool? threadBindingEnabled,
    String? taskCompletionAction,
    bool? workspaceGitSyncEnabled,
    bool? workspaceGitSyncPushEnabled,
    Object? projectSetup = _unset,
  }) {
    return E2EFixture(
      fixtureProfile: fixtureProfile ?? this.fixtureProfile,
      projectId: projectId ?? this.projectId,
      projectRemote: projectRemote ?? this.projectRemote,
      useLocalProjectPath: useLocalProjectPath ?? this.useLocalProjectPath,
      projectBranch: projectBranch ?? this.projectBranch,
      projectCredentials: identical(projectCredentials, _unset) ? this.projectCredentials : projectCredentials as String?,
      projectDefault: projectDefault ?? this.projectDefault,
      port: port ?? this.port,
      provider: provider ?? this.provider,
      workflowModel: workflowModel ?? this.workflowModel,
      plannerModel: plannerModel ?? this.plannerModel,
      executorModel: executorModel ?? this.executorModel,
      reviewerModel: reviewerModel ?? this.reviewerModel,
      poolSize: poolSize ?? this.poolSize,
      sandbox: sandbox ?? this.sandbox,
      guardsEnabled: guardsEnabled ?? this.guardsEnabled,
      dailyTokenBudget: dailyTokenBudget ?? this.dailyTokenBudget,
      loopDetectionEnabled: loopDetectionEnabled ?? this.loopDetectionEnabled,
      loggingLevel: loggingLevel ?? this.loggingLevel,
      threadBindingEnabled: threadBindingEnabled ?? this.threadBindingEnabled,
      taskCompletionAction: taskCompletionAction ?? this.taskCompletionAction,
      workspaceGitSyncEnabled: workspaceGitSyncEnabled ?? this.workspaceGitSyncEnabled,
      workspaceGitSyncPushEnabled: workspaceGitSyncPushEnabled ?? this.workspaceGitSyncPushEnabled,
      projectSetup: identical(projectSetup, _unset) ? this.projectSetup : projectSetup as E2EProjectSetup?,
    );
  }
}

final class E2EFixtureInstance {
  final Directory runtimeDir;
  final String dataDir;
  final String workspaceDir;
  final String workflowWorkspaceDir;
  final String projectDir;
  final String fixtureProfileDir;
  final DartclawConfig config;

  E2EFixtureInstance._({
    required this.runtimeDir,
    required this.dataDir,
    required this.workspaceDir,
    required this.workflowWorkspaceDir,
    required this.projectDir,
    required this.fixtureProfileDir,
    required this.config,
  });

  Future<CliWorkflowWiring> wire({
    WorkflowStepOutputTransformer? outputTransformer,
    CliWorkflowPrCreator? prCreator,
    HarnessFactory? harnessFactory,
  }) async {
    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: config.server.dataDir,
      harnessFactory: harnessFactory,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      workflowStepOutputTransformer: outputTransformer,
      prCreator: prCreator,
    );
    await wiring.wire();
    return wiring;
  }

  Future<void> dispose() async {
    if (runtimeDir.existsSync()) {
      await runtimeDir.delete(recursive: true);
    }
  }
}

const _unset = Object();
