import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_core/dartclaw_core.dart' show SearchDbFactory, TaskDbFactory, openSearchDb, openTaskDb;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProviderAuthPreflight,
        SkillIntrospector,
        WorkflowDefinition,
        WorkflowContext,
        WorkflowPreflightException,
        WorkflowRoleDefaults,
        WorkflowRun,
        WorkflowStep,
        WorkflowTaskType,
        syntheticWorkflowSkillSteps,
        resolveStepConfig;
import 'package:meta/meta.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show
        CredentialPreflight,
        CredentialPreflightException,
        DartclawRuntime,
        LogRedactor,
        LogService,
        WriteLine,
        workflowRoleDefaultsFromConfig;

import '../config_loader.dart';
import '../connected_command_support.dart';

/// Installs the root-logger sink for a standalone run from the config's
/// `logging:` section.
///
/// Standalone lanes compose the runtime headlessly and print only their own
/// progress lines, so without this every runtime diagnostic — provider stderr
/// included — is discarded and the configured level is inert. Callers own
/// [LogService.dispose].
LogService installStandaloneLogging(DartclawConfig config) {
  final logService = LogService.fromConfig(
    format: config.logging.format,
    logFile: config.logging.file,
    level: config.logging.level,
    redactor: LogRedactor(redactor: MessageRedactor(extraPatterns: config.logging.redactPatterns)),
  );
  logService.install();
  return logService;
}

/// The composed in-process runtime plus the loaded run, handed to a standalone
/// lifecycle action callback.
class StandaloneLifecycleSession {
  final DartclawRuntime runtime;
  final WorkflowRun run;

  const new({required this.runtime, required this.run});
}

/// Base for `workflow` subcommands that can drive a single run's lifecycle
/// either against a live server (connected) or in-process (`--standalone`).
///
/// Supplies the standalone dependency-injection surface (db/harness factories,
/// environment, sinks, interrupts) plus [runStandaloneLifecycle], which mirrors
/// `workflow run --standalone` for local DB access and live-server protection:
/// config resolution, the server-reachable safety check (abort unless
/// `--force`), the project-credential preflight, the headless
/// [DartclawRuntime] staging + completion + shutdown,
/// run-not-found handling, and a `StateError`→printed-message + non-zero-exit
/// mapping so engine guard violations (and stale-`running` resumes) never
/// surface a stack trace.
abstract class StandaloneWorkflowLifecycleCommand extends ConnectedCommand {
  final SearchDbFactory? searchDbFactory;
  final TaskDbFactory? taskDbFactory;
  final HarnessFactory? harnessFactory;
  final Map<String, String>? environment;
  @protected
  final WriteLine stderrLine;
  final Stream<void> Function() interrupts;
  final bool runWorkflowSkillsBootstrap;
  final SkillIntrospector? skillIntrospector;
  final ProviderAuthPreflight? providerAuthPreflight;

  new({
    super.config,
    super.apiClient,
    super.writeLine,
    super.exitFn,
    this.searchDbFactory,
    this.taskDbFactory,
    this.harnessFactory,
    this.environment,
    WriteLine? stderrLine,
    Stream<void> Function()? interrupts,
    this.runWorkflowSkillsBootstrap = true,
    this.skillIntrospector,
    this.providerAuthPreflight,
  }) : stderrLine = stderrLine ?? stderr.writeln,
       interrupts = interrupts ?? (() => ProcessSignal.sigint.watch().map((_) {})) {
    argParser
      ..addFlag('standalone', negatable: false, help: 'Drive the workflow run in-process without using the server API')
      ..addFlag('force', negatable: false, help: 'Bypass the standalone live-server safety check');
  }

  /// True when `--standalone` was passed.
  @protected
  bool get isStandalone => argResults!['standalone'] as bool;

  /// Rejects `--force` unless `--standalone` is also present, matching
  /// `workflow run`'s flag contract.
  @protected
  void requireForceWithStandalone() {
    if ((argResults!['force'] as bool) && !isStandalone) {
      throw UsageException('--force can only be used together with --standalone', usage);
    }
  }

  /// Builds the in-process engine, loads [runId], and runs [action] against it.
  ///
  /// When [provisionWorkers] is true (resume/retry, which execute steps),
  /// workers are provisioned for the run definition's providers before
  /// [action] runs; cancel/pause pass false. [action] returns the process exit
  /// code; a `StateError` it throws (engine guard violation) is mapped to its
  /// message on stderr + exit `1`.
  ///
  /// [runWorkflowSkillsBootstrap] overrides the command-level
  /// [StandaloneWorkflowLifecycleCommand.runWorkflowSkillsBootstrap] for this
  /// call; null inherits it. Lifecycle-only verbs (cancel/pause) pass `false`:
  /// they only transition persisted run state, so DC-native skill provisioning
  /// is unnecessary work — and a hard failure when the version-pinned asset dir
  /// was never downloaded.
  @protected
  Future<void> runStandaloneLifecycle({
    required String runId,
    required bool provisionWorkers,
    required Future<int> Function(StandaloneLifecycleSession session) action,
    bool? runWorkflowSkillsBootstrap,
  }) async {
    final bootstrapSkills = runWorkflowSkillsBootstrap ?? this.runWorkflowSkillsBootstrap;
    final force = argResults!['force'] as bool;
    final configPath = resolveStandaloneWorkflowConfigPath(
      configPath: globalOptionString(globalResults, 'config'),
      env: environment,
    );
    final config = injectedConfig ?? loadCliConfig(configPath: configPath, env: environment);

    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: injectedApiClient, config: config);
    final serverReachable = await apiClient.probeHealth();
    if (serverReachable && !force) {
      stderrLine(
        'A DartClaw server is running at ${apiClient.baseUri.origin}. Use connected mode or add --force to override.',
      );
      exitFn(1);
    }

    final dataDir = config.server.dataDir;
    if (!Directory(dataDir).existsSync()) {
      stderrLine('Workflow run not found: $runId');
      exitFn(1);
    }

    final logService = installStandaloneLogging(config);

    final env = environment ?? Platform.environment;
    try {
      CredentialPreflight.enforce(config, env);
    } on CredentialPreflightException catch (error) {
      for (final item in error.errors) {
        stderrLine(item.message);
      }
      exitFn(1);
    }

    final staging = await DartclawRuntime.stageHeadless(
      config,
      dataDir: dataDir,
      environment: env,
      skillProvisionerEnvironment: env,
      harnessFactory: harnessFactory ?? HarnessFactory(),
      searchDbFactory: searchDbFactory ?? openSearchDb,
      taskDbFactory: taskDbFactory ?? openTaskDb,
      stderrLine: stderrLine,
      exitFn: exitFn,
      runWorkflowSkillsBootstrap: bootstrapSkills,
      skillIntrospector: skillIntrospector,
      providerAuthPreflight: providerAuthPreflight,
    );

    DartclawRuntime? runtime;
    try {
      final run = await staging.loadWorkflowRun(runId);
      if (run == null) {
        stderrLine('Workflow run not found: $runId');
        exitFn(1);
      }

      if (provisionWorkers) {
        final definition = WorkflowDefinition.fromJson(run.definitionJson);
        final executionProviders = requiredWorkflowProviders(
          definition,
          config,
          context: WorkflowContext.fromJson(run.contextJson),
        );
        try {
          await staging.preflightProviderAuth(executionProviders);
        } on WorkflowPreflightException catch (error) {
          stderrLine(error.message);
          exitFn(1);
        }
        runtime = await staging.completeForExecution(executionProviders);
      } else {
        runtime = await staging.completeForLifecycle();
      }

      try {
        final code = await action(StandaloneLifecycleSession(runtime: runtime, run: run));
        exitFn(code);
      } on StateError catch (error) {
        stderrLine(error.message);
        exitFn(1);
      }
    } finally {
      if (runtime != null) {
        await runtime.shutdown();
      } else {
        await staging.dispose();
      }
      await logService.dispose();
    }
  }
}

/// The set of providers that can execute provider-backed workflow turns.
Set<String> requiredWorkflowProviders(
  WorkflowDefinition definition,
  DartclawConfig config, {
  WorkflowContext? context,
}) {
  final roleDefaults = workflowRoleDefaultsFromConfig(config);
  final stepsById = {for (final step in definition.steps) step.id: step};
  final providers = <String>{};
  void addProvider(WorkflowStep step) {
    final provider = _effectiveAgentStepProvider(definition, step, config, roleDefaults, stepsById);
    if (provider.trim().isEmpty) {
      throw StateError('Workflow step "${step.id}" provider must not be blank');
    }
    providers.add(ProviderIdentity.normalize(provider));
  }

  for (final step in definition.steps) {
    if (step.taskType != WorkflowTaskType.agent) continue;
    addProvider(step);
  }
  for (final step in syntheticWorkflowSkillSteps(
    definition,
    context: context ?? WorkflowContext(),
    roleDefaults: roleDefaults,
  )) {
    addProvider(step);
  }
  return providers;
}

String _effectiveAgentStepProvider(
  WorkflowDefinition definition,
  WorkflowStep step,
  DartclawConfig config,
  WorkflowRoleDefaults roleDefaults,
  Map<String, WorkflowStep> stepsById,
) {
  final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: roleDefaults);
  final rootStep = step.continueSession == null ? null : _resolveContinueSessionRootStep(definition, step, stepsById);
  if (rootStep == null) {
    return resolved.provider ?? config.agent.provider;
  }
  final rootResolved = resolveStepConfig(rootStep, definition.stepDefaults, roleDefaults: roleDefaults);
  return rootResolved.provider ?? resolved.provider ?? config.agent.provider;
}

WorkflowStep? _resolveContinueSessionRootStep(
  WorkflowDefinition definition,
  WorkflowStep step,
  Map<String, WorkflowStep> stepsById,
) {
  final visited = <String>{step.id};
  var current = step;

  while (current.continueSession != null) {
    final targetStepId = _resolveContinueSessionTargetStepId(definition, current);
    if (targetStepId == null || !visited.add(targetStepId)) return null;
    final targetStep = stepsById[targetStepId];
    if (targetStep == null) return null;
    if (targetStep.continueSession == null) return targetStep;
    current = targetStep;
  }

  return null;
}

String? _resolveContinueSessionTargetStepId(WorkflowDefinition definition, WorkflowStep step) {
  final ref = step.continueSession;
  if (ref == null) return null;
  if (ref != '@previous') return ref;
  final index = definition.steps.indexWhere((candidate) => candidate.id == step.id);
  if (index <= 0) return null;
  return definition.steps[index - 1].id;
}
