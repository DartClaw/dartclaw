import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SearchDbFactory, TaskDbFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProviderAuthPreflight,
        SkillIntrospector,
        WorkflowDefinition,
        WorkflowContext,
        WorkflowPreflightException,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        WorkflowRun,
        WorkflowStep,
        WorkflowTaskType,
        syntheticWorkflowSkillSteps,
        resolveStepConfig;
import 'package:meta/meta.dart';

import '../config_loader.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show WriteLine;
import 'cli_workflow_wiring.dart';
import 'credential_preflight.dart';

/// The wired in-process engine plus the loaded run, handed to a standalone
/// lifecycle action callback.
class StandaloneLifecycleSession {
  final CliWorkflowWiring wiring;
  final WorkflowRun run;

  const StandaloneLifecycleSession({required this.wiring, required this.run});
}

/// Base for `workflow` subcommands that can drive a single run's lifecycle
/// either against a live server (connected) or in-process (`--standalone`).
///
/// Supplies the standalone dependency-injection surface (db/harness factories,
/// environment, sinks, interrupts) plus [runStandaloneLifecycle], which mirrors
/// `workflow run --standalone` for local DB access and live-server protection:
/// config resolution, the server-reachable safety check (abort unless
/// `--force`), the [CliWorkflowWiring] build + `wire()`/`dispose()`, run-not-found
/// handling, and a `StateError`→printed-message + non-zero-exit mapping so engine
/// guard violations (and stale-`running` resumes) never surface a stack trace.
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

  StandaloneWorkflowLifecycleCommand({
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
  /// When [provisionTaskRunners] is true (resume/retry, which execute steps),
  /// task runners are provisioned for the run definition's providers before
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
    required bool provisionTaskRunners,
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

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: dataDir,
      environment: environment,
      harnessFactory: harnessFactory,
      searchDbFactory: searchDbFactory,
      taskDbFactory: taskDbFactory,
      runWorkflowSkillsBootstrap: bootstrapSkills,
      skillIntrospector: skillIntrospector,
      providerAuthPreflight: providerAuthPreflight,
    );
    var preWired = false;
    try {
      try {
        await wiring.wirePreHarness();
        preWired = true;
      } on CredentialPreflightException catch (error) {
        for (final item in error.errors) {
          stderrLine(item.message);
        }
        exitFn(1);
      }

      final run = await wiring.loadRun(runId);
      if (run == null) {
        stderrLine('Workflow run not found: $runId');
        exitFn(1);
      }

      if (provisionTaskRunners) {
        final definition = WorkflowDefinition.fromJson(run.definitionJson);
        final harnessProviders = requiredWorkflowProviders(
          definition,
          config,
          context: WorkflowContext.fromJson(run.contextJson),
        );
        try {
          await wiring.preflightProviderAuth(harnessProviders);
        } on WorkflowPreflightException catch (error) {
          stderrLine(error.message);
          exitFn(1);
        }
        await wiring.startHarnesses(harnessProviders);
      } else {
        await wiring.wireLifecycleOnly();
      }

      try {
        final code = await action(StandaloneLifecycleSession(wiring: wiring, run: run));
        exitFn(code);
      } on StateError catch (error) {
        stderrLine(error.message);
        exitFn(1);
      }
    } finally {
      if (preWired) {
        await wiring.dispose();
      }
    }
  }
}

/// The set of providers that can execute provider-backed workflow turns.
Set<String> requiredWorkflowProviders(
  WorkflowDefinition definition,
  DartclawConfig config, {
  WorkflowContext? context,
}) {
  final roleDefaults = _workflowRoleDefaults(config);
  final stepsById = {for (final step in definition.steps) step.id: step};
  final providers = <String>{};
  for (final step in definition.steps) {
    if (step.taskType != WorkflowTaskType.agent) continue;
    providers.add(_effectiveAgentStepProvider(definition, step, config, roleDefaults, stepsById));
  }
  for (final step in syntheticWorkflowSkillSteps(
    definition,
    context: context ?? WorkflowContext(),
    roleDefaults: roleDefaults,
  )) {
    providers.add(_effectiveAgentStepProvider(definition, step, config, roleDefaults, stepsById));
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

WorkflowRoleDefaults _workflowRoleDefaults(DartclawConfig config) {
  return WorkflowRoleDefaults(
    workflow: WorkflowRoleDefault(
      provider: config.workflow.defaults.workflow.provider,
      model: config.workflow.defaults.workflow.model,
      effort: config.workflow.defaults.workflow.effort,
    ),
    planner: WorkflowRoleDefault(
      provider: config.workflow.defaults.planner.provider,
      model: config.workflow.defaults.planner.model,
      effort: config.workflow.defaults.planner.effort,
    ),
    executor: WorkflowRoleDefault(
      provider: config.workflow.defaults.executor.provider,
      model: config.workflow.defaults.executor.model,
      effort: config.workflow.defaults.executor.effort,
    ),
    reviewer: WorkflowRoleDefault(
      provider: config.workflow.defaults.reviewer.provider,
      model: config.workflow.defaults.reviewer.model,
      effort: config.workflow.defaults.reviewer.effort,
    ),
  );
}
