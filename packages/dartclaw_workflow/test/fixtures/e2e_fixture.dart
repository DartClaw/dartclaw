import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_security/dartclaw_security.dart' show GuardConfig;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SkillProvisioner, WorkflowStepOutputTransformer;
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

/// Resolved provider + per-role model defaults for [E2EFixture].
///
/// Honors the precedence rule: explicit constructor arg > `DARTCLAW_TEST_*`
/// env var > hardcoded default. Empty-string env vars are treated as unset.
typedef _ResolvedDefaults = ({
  String provider,
  String workflowModel,
  String plannerModel,
  String executorModel,
  String reviewerModel,
  String sandbox,
});

typedef _ProviderPreset = ({
  String workflowModel,
  String plannerModel,
  String executorModel,
  String reviewerModel,
  String sandbox,
});

const _ProviderPreset _codexPreset = (
  workflowModel: 'gpt-5.4',
  plannerModel: 'gpt-5.4',
  executorModel: 'gpt-5.3-codex-spark',
  reviewerModel: 'gpt-5.3-codex-spark',
  sandbox: 'danger-full-access',
);

const _ProviderPreset _claudePreset = (
  workflowModel: 'claude-opus-4-7',
  plannerModel: 'claude-opus-4-7',
  executorModel: 'claude-sonnet-4-6',
  reviewerModel: 'claude-sonnet-4-6',
  sandbox: 'bypassPermissions',
);

const String _envProvider = 'DARTCLAW_TEST_PROVIDER';
const String _envWorkflowModel = 'DARTCLAW_TEST_WORKFLOW_MODEL';
const String _envPlannerModel = 'DARTCLAW_TEST_PLANNER_MODEL';
const String _envExecutorModel = 'DARTCLAW_TEST_EXECUTOR_MODEL';
const String _envReviewerModel = 'DARTCLAW_TEST_REVIEWER_MODEL';

String? _envOrNull(Map<String, String> env, String key) {
  final v = env[key];
  return (v == null || v.isEmpty) ? null : v;
}

_ProviderPreset _presetFor(String provider) {
  if (provider == 'claude') return _claudePreset;
  if (provider == 'codex') return _codexPreset;
  throw ArgumentError.value(provider, 'provider', 'must be "codex" or "claude"');
}

/// Resolves provider + per-role model defaults at construction time, applying
/// the explicit arg > env var > preset default precedence rule. Reads the
/// supplied [env] (typically `Platform.environment`) once and returns an
/// immutable record so the fixture pins values at build time, not lazily on
/// access.
_ResolvedDefaults _resolveDefaults({
  String? providerArg,
  String? workflowModelArg,
  String? plannerModelArg,
  String? executorModelArg,
  String? reviewerModelArg,
  String? sandboxArg,
  Map<String, String>? env,
}) {
  final e = env ?? Platform.environment;
  final provider = providerArg ?? _envOrNull(e, _envProvider) ?? 'codex';
  final preset = _presetFor(provider);
  return (
    provider: provider,
    workflowModel: workflowModelArg ?? _envOrNull(e, _envWorkflowModel) ?? preset.workflowModel,
    plannerModel: plannerModelArg ?? _envOrNull(e, _envPlannerModel) ?? preset.plannerModel,
    executorModel: executorModelArg ?? _envOrNull(e, _envExecutorModel) ?? preset.executorModel,
    reviewerModel: reviewerModelArg ?? _envOrNull(e, _envReviewerModel) ?? preset.reviewerModel,
    sandbox: sandboxArg ?? preset.sandbox,
  );
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
  final bool provisionWorkflowSkills;
  final E2EProjectSetup? projectSetup;
  final Map<String, String> environment;

  factory E2EFixture({
    String fixtureProfile = 'workflow-e2e-profile',
    String projectId = 'workflow-test-todo-app',
    String projectRemote = 'git@github.com:DartClaw/workflow-test-todo-app.git',
    bool useLocalProjectPath = false,
    String projectBranch = 'main',
    String? projectCredentials = 'github-main',
    bool projectDefault = true,
    int port = 3333,
    String? provider,
    String? workflowModel,
    String? plannerModel,
    String? executorModel,
    String? reviewerModel,
    int poolSize = 3,
    String? sandbox,
    bool guardsEnabled = true,
    int dailyTokenBudget = 5000000,
    bool loopDetectionEnabled = true,
    String loggingLevel = 'FINE',
    bool threadBindingEnabled = true,
    String taskCompletionAction = 'accept',
    bool workspaceGitSyncEnabled = false,
    bool workspaceGitSyncPushEnabled = true,
    bool provisionWorkflowSkills = false,
    E2EProjectSetup? projectSetup,
    Map<String, String>? environment,
  }) {
    final resolved = _resolveDefaults(
      providerArg: provider,
      workflowModelArg: workflowModel,
      plannerModelArg: plannerModel,
      executorModelArg: executorModel,
      reviewerModelArg: reviewerModel,
      sandboxArg: sandbox,
      env: environment,
    );
    return E2EFixture._(
      fixtureProfile: fixtureProfile,
      projectId: projectId,
      projectRemote: projectRemote,
      useLocalProjectPath: useLocalProjectPath,
      projectBranch: projectBranch,
      projectCredentials: projectCredentials,
      projectDefault: projectDefault,
      port: port,
      provider: resolved.provider,
      workflowModel: resolved.workflowModel,
      plannerModel: resolved.plannerModel,
      executorModel: resolved.executorModel,
      reviewerModel: resolved.reviewerModel,
      poolSize: poolSize,
      sandbox: resolved.sandbox,
      guardsEnabled: guardsEnabled,
      dailyTokenBudget: dailyTokenBudget,
      loopDetectionEnabled: loopDetectionEnabled,
      loggingLevel: loggingLevel,
      threadBindingEnabled: threadBindingEnabled,
      taskCompletionAction: taskCompletionAction,
      workspaceGitSyncEnabled: workspaceGitSyncEnabled,
      workspaceGitSyncPushEnabled: workspaceGitSyncPushEnabled,
      provisionWorkflowSkills: provisionWorkflowSkills,
      projectSetup: projectSetup,
      environment: Map<String, String>.unmodifiable(environment ?? Platform.environment),
    );
  }

  const E2EFixture._({
    required this.fixtureProfile,
    required this.projectId,
    required this.projectRemote,
    required this.useLocalProjectPath,
    required this.projectBranch,
    required this.projectCredentials,
    required this.projectDefault,
    required this.port,
    required this.provider,
    required this.workflowModel,
    required this.plannerModel,
    required this.executorModel,
    required this.reviewerModel,
    required this.poolSize,
    required this.sandbox,
    required this.guardsEnabled,
    required this.dailyTokenBudget,
    required this.loopDetectionEnabled,
    required this.loggingLevel,
    required this.threadBindingEnabled,
    required this.taskCompletionAction,
    required this.workspaceGitSyncEnabled,
    required this.workspaceGitSyncPushEnabled,
    required this.provisionWorkflowSkills,
    required this.projectSetup,
    required this.environment,
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

  /// Switches provider and aligns unspecified per-role models with the new
  /// provider's preset (so `withProvider(value: 'claude', ...)` does not leave
  /// codex executor/reviewer strings carried over from the prior fixture).
  /// Explicit per-role arguments still win.
  E2EFixture withProvider({
    required String value,
    required String workflowModel,
    String? plannerModel,
    String? executorModel,
    String? reviewerModel,
    String? sandbox,
  }) {
    final preset = _presetFor(value);
    return _copy(
      provider: value,
      workflowModel: workflowModel,
      plannerModel: plannerModel ?? preset.plannerModel,
      executorModel: executorModel ?? preset.executorModel,
      reviewerModel: reviewerModel ?? preset.reviewerModel,
      sandbox: sandbox ?? preset.sandbox,
    );
  }

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
    final runtimeCwd = p.join(dataDir, 'runtime-cwd');
    final projectDir = p.join(dataDir, 'projects', projectId);

    _copyDirectorySync(Directory(p.join(profileDir, 'workspace')), Directory(workspaceDir));
    _copyDirectorySync(Directory(p.join(profileDir, 'workflow-workspace')), Directory(workflowWorkspaceDir));
    Directory(runtimeCwd).createSync(recursive: true);
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
          ).resolveFrom(environment),
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
            options: provider == 'claude' ? {'permissionMode': sandbox} : {'approval': 'never', 'sandbox': sandbox},
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

    if (provisionWorkflowSkills) {
      final sourceDir = _builtInSkillsSourceDir();
      final provisioner = SkillProvisioner(
        config: config.andthen,
        dataDir: dataDir,
        dcNativeSkillsSourceDir: sourceDir,
      );
      provisioner.validateSpawnTargets([runtimeCwd, projectDir]);
      await provisioner.ensureCacheCurrent();
    }

    return E2EFixtureInstance._(
      runtimeDir: runtimeDir,
      dataDir: dataDir,
      workspaceDir: workspaceDir,
      workflowWorkspaceDir: workflowWorkspaceDir,
      runtimeCwd: runtimeCwd,
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
    bool? provisionWorkflowSkills,
    Object? projectSetup = _unset,
    Map<String, String>? environment,
  }) {
    return E2EFixture._(
      fixtureProfile: fixtureProfile ?? this.fixtureProfile,
      projectId: projectId ?? this.projectId,
      projectRemote: projectRemote ?? this.projectRemote,
      useLocalProjectPath: useLocalProjectPath ?? this.useLocalProjectPath,
      projectBranch: projectBranch ?? this.projectBranch,
      projectCredentials: identical(projectCredentials, _unset)
          ? this.projectCredentials
          : projectCredentials as String?,
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
      provisionWorkflowSkills: provisionWorkflowSkills ?? this.provisionWorkflowSkills,
      projectSetup: identical(projectSetup, _unset) ? this.projectSetup : projectSetup as E2EProjectSetup?,
      environment: Map<String, String>.unmodifiable(environment ?? this.environment),
    );
  }

  /// Renders [`workflow_profile.yaml`](workflow-e2e-profile/workflow_profile.yaml)
  /// for this fixture's resolved provider + per-role models, substituting the
  /// `__DATA_DIR__` / `__WORKFLOW_WORKSPACE_DIR__` placeholders with the
  /// supplied paths. Returns the rendered YAML string.
  ///
  /// The fixture itself does not currently consume the rendered YAML at
  /// runtime — it builds [DartclawConfig] programmatically — but goldens
  /// in `e2e_fixture_test.dart` exercise this method to lock the templating
  /// shape across provider presets.
  String renderProfileYaml({required String dataDir, required String workflowWorkspaceDir, String? templatePath}) {
    final path = templatePath ?? p.join(_fixturesRoot(), fixtureProfile, 'workflow_profile.yaml');
    final template = File(path).readAsStringSync();
    final providerBlock = _renderProvidersBlock();
    final credentialBlock = _renderProviderCredentialBlock();
    return template
        .replaceAll('__DATA_DIR__', dataDir)
        .replaceAll('__WORKFLOW_WORKSPACE_DIR__', workflowWorkspaceDir)
        .replaceAll('__AGENT_PROVIDER__', provider)
        .replaceAll('__AGENT_MODEL__', workflowModel)
        .replaceAll('__PROVIDERS_BLOCK__', providerBlock)
        .replaceAll('__PROVIDER_CREDENTIAL_BLOCK__', credentialBlock)
        .replaceAll('__WORKFLOW_MODEL__', '$provider/$workflowModel')
        .replaceAll('__PLANNER_MODEL__', '$provider/$plannerModel')
        .replaceAll('__EXECUTOR_MODEL__', '$provider/$executorModel')
        .replaceAll('__REVIEWER_MODEL__', '$provider/$reviewerModel');
  }

  String _renderProvidersBlock() {
    if (provider == 'claude') {
      return 'providers:\n'
          '  claude:\n'
          '    executable: claude\n'
          '    pool_size: $poolSize\n'
          '    permissionMode: $sandbox';
    }
    return 'providers:\n'
        '  codex:\n'
        '    executable: codex\n'
        '    pool_size: $poolSize\n'
        '    approval: never\n'
        '    sandbox: $sandbox';
  }

  String _renderProviderCredentialBlock() {
    if (provider == 'claude') {
      return 'anthropic:\n    api_key: \${ANTHROPIC_API_KEY}';
    }
    return 'openai:\n    api_key: \${CODEX_API_KEY}';
  }
}

final class E2EFixtureInstance {
  final Directory runtimeDir;
  final String dataDir;
  final String workspaceDir;
  final String workflowWorkspaceDir;
  final String runtimeCwd;
  final String projectDir;
  final String fixtureProfileDir;
  final DartclawConfig config;

  E2EFixtureInstance._({
    required this.runtimeDir,
    required this.dataDir,
    required this.workspaceDir,
    required this.workflowWorkspaceDir,
    required this.runtimeCwd,
    required this.projectDir,
    required this.fixtureProfileDir,
    required this.config,
  });

  Future<CliWorkflowWiring> wire({
    WorkflowStepOutputTransformer? outputTransformer,
    CliWorkflowPrCreator? prCreator,
    HarnessFactory? harnessFactory,
    String? skillsHomeDir,
  }) async {
    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: config.server.dataDir,
      runtimeCwd: runtimeCwd,
      skillsHomeDir: skillsHomeDir,
      harnessFactory: harnessFactory,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      workflowStepOutputTransformer: outputTransformer,
      prCreator: prCreator,
    );
    await wiring.wire();
    return wiring;
  }

  void writeDataDirWorkflowSkills(Iterable<String> names) {
    for (final root in [p.join(dataDir, '.claude', 'skills'), p.join(dataDir, '.agents', 'skills')]) {
      for (final name in names) {
        final skillDir = Directory(p.join(root, name))..createSync(recursive: true);
        File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\n---\n\n# $name\n');
      }
    }
  }

  Future<void> dispose() async {
    if (runtimeDir.existsSync()) {
      await runtimeDir.delete(recursive: true);
    }
  }
}

const _unset = Object();

extension on CredentialEntry {
  CredentialEntry resolveFrom(Map<String, String> environment) {
    if (isPresent) return this;
    for (final envVar in envVars) {
      final value = environment[envVar]?.trim();
      if (value == null || value.isEmpty) continue;
      return switch (type) {
        CredentialType.apiKey => CredentialEntry(apiKey: value, envVars: envVars),
        CredentialType.githubToken => CredentialEntry.githubToken(
          token: value,
          repository: repository,
          envVars: envVars,
        ),
      };
    }
    return this;
  }
}

String _builtInSkillsSourceDir() {
  var current = Directory.current;
  while (true) {
    final candidate = p.join(current.path, 'packages', 'dartclaw_workflow', 'skills');
    if (Directory(candidate).existsSync()) return candidate;
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate DartClaw built-in skills source');
    }
    current = parent;
  }
}
