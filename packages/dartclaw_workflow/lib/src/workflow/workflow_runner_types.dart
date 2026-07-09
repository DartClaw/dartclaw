import 'dart:async' show FutureOr;

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentExecutionRepository,
        EventBus,
        ExecutionRepositoryTransactor,
        HarnessFactory,
        KvService,
        ProjectService,
        Task,
        TaskRepository,
        WorkflowStepExecutionRepository,
        WorkflowTaskService;
import 'workflow_definition.dart'
    show ActionNode, ForeachNode, LoopNode, MapNode, ParallelGroupNode, WorkflowDefinition, WorkflowNode, WorkflowStep;
import 'workflow_run.dart' show WorkflowRun;
import 'workflow_run_repository.dart' show WorkflowRunRepository;
import 'package:uuid/uuid.dart';

import 'context_extractor.dart';
import 'gate_evaluator.dart';
import '../skills/provider_auth_preflight.dart';
import 'prompt_augmenter.dart';
import 'skill_introspector.dart';
import 'skill_prompt_builder.dart';
import 'step_config_resolver.dart';
import 'workflow_context.dart';
import 'workflow_git_port.dart';
import 'workflow_template_engine.dart';
import 'workflow_turn_adapter.dart';

typedef WorkflowStepOutputTransformer =
    FutureOr<Map<String, dynamic>> Function(
      WorkflowRun run,
      WorkflowDefinition definition,
      WorkflowStep step,
      Task task,
      Map<String, dynamic> outputs,
    );

/// Returns true for the normalized AST node types this runner package handles.
bool isSupportedWorkflowRunnerNode(WorkflowNode node) => switch (node) {
  ActionNode() || MapNode() || ParallelGroupNode() || LoopNode() || ForeachNode() => true,
};

/// Typed validation failure produced while normalizing step outputs.
final class StepValidationFailure {
  final String reason;
  final List<String> missingArtifacts;

  const StepValidationFailure({required this.reason, this.missingArtifacts = const <String>[]});

  List<String> get missingPaths => missingArtifacts;

  @override
  String toString() => reason;
}

typedef StorySpecOutputValidation = ({Map<String, dynamic> outputs, StepValidationFailure? validationFailure});

/// Result of a single workflow step execution.
class StepOutcome {
  final WorkflowStep step;
  final Task? task;
  final Map<String, dynamic> outputs;
  final int tokenCount;
  final bool success;
  final String? error;
  final String? outcome;
  final String? outcomeReason;
  final bool awaitingApproval;

  /// Set by a nested loop that escalated on exhaustion (`onMaxIterations:
  /// escalate`): the enclosing foreach must hold open dependents for human
  /// review even under `onFailure: continue`. Carried explicitly so the hold
  /// never depends on structural fingerprints of the outcome (task type,
  /// null task).
  final bool requiresDependencyHold;
  final StepValidationFailure? validationFailure;

  const StepOutcome({
    required this.step,
    this.task,
    this.outputs = const {},
    this.tokenCount = 0,
    required this.success,
    this.error,
    this.outcome,
    this.outcomeReason,
    this.awaitingApproval = false,
    this.requiresDependencyHold = false,
    this.validationFailure,
  });
}

/// Result of a map/fan-out step execution.
final class MapStepResult {
  final List<dynamic> results;
  final int totalTokens;
  final bool success;
  final String? error;

  const MapStepResult({required this.results, required this.totalTokens, required this.success, this.error});
}

final class StepExecutionContext {
  final WorkflowTaskService taskService;
  final EventBus eventBus;
  final KvService kvService;
  final WorkflowRunRepository repository;
  final GateEvaluator gateEvaluator;
  final ContextExtractor contextExtractor;
  final WorkflowTurnAdapter? turnAdapter;
  final WorkflowStepOutputTransformer? outputTransformer;
  final SkillIntrospector? skillIntrospector;
  final ProviderAuthPreflight? providerAuthPreflight;
  final WorkflowSkillPreflightConfig skillPreflightConfig;
  final TaskRepository? taskRepository;
  final AgentExecutionRepository? agentExecutionRepository;
  final WorkflowStepExecutionRepository? workflowStepExecutionRepository;
  final ExecutionRepositoryTransactor? executionTransactor;
  final ProjectService? projectService;
  final String? defaultWorkspaceRoot;
  final String? dataDir;
  final WorkflowTemplateEngine? templateEngine;
  final WorkflowGitPort? workflowGitPort;
  final SkillPromptBuilder? skillPromptBuilder;
  final WorkflowRoleDefaults roleDefaults;
  final Map<String, String>? hostEnvironment;
  final List<String> bashStepEnvAllowlist;
  final List<String> bashStepExtraStripPatterns;
  final Uuid uuid;
  final WorkflowRun? run;
  final WorkflowDefinition? definition;
  final WorkflowContext? workflowContext;

  StepExecutionContext({
    required this.taskService,
    required this.eventBus,
    required this.kvService,
    required this.repository,
    required this.gateEvaluator,
    required this.contextExtractor,
    this.turnAdapter,
    this.outputTransformer,
    this.skillIntrospector,
    this.providerAuthPreflight,
    this.skillPreflightConfig = const WorkflowSkillPreflightConfig(),
    this.taskRepository,
    this.agentExecutionRepository,
    this.workflowStepExecutionRepository,
    this.executionTransactor,
    this.projectService,
    this.defaultWorkspaceRoot,
    this.dataDir,
    this.templateEngine,
    this.workflowGitPort,
    this.skillPromptBuilder,
    this.roleDefaults = const WorkflowRoleDefaults(),
    this.hostEnvironment,
    this.bashStepEnvAllowlist = BashStepPolicy.defaultEnvAllowlist,
    this.bashStepExtraStripPatterns = const <String>[],
    Uuid? uuid,
    this.run,
    this.definition,
    this.workflowContext,
  }) : uuid = uuid ?? const Uuid();

  StepExecutionContext configured({
    required String dataDir,
    required StepPromptConfiguration promptConfiguration,
    required WorkflowRoleDefaults roleDefaults,
    required BashStepPolicy bashStepPolicy,
    required Uuid uuid,
  }) {
    return StepExecutionContext(
      taskService: taskService,
      eventBus: eventBus,
      kvService: kvService,
      repository: repository,
      gateEvaluator: gateEvaluator,
      contextExtractor: contextExtractor,
      turnAdapter: turnAdapter,
      outputTransformer: outputTransformer,
      skillIntrospector: skillIntrospector,
      providerAuthPreflight: providerAuthPreflight,
      skillPreflightConfig: skillPreflightConfig,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionTransactor: executionTransactor,
      projectService: projectService,
      defaultWorkspaceRoot: defaultWorkspaceRoot,
      dataDir: dataDir,
      templateEngine: promptConfiguration.templateEngine,
      workflowGitPort: workflowGitPort,
      skillPromptBuilder: promptConfiguration.skillPromptBuilder,
      roleDefaults: roleDefaults,
      hostEnvironment: bashStepPolicy.hostEnvironment,
      bashStepEnvAllowlist: List.unmodifiable(bashStepPolicy.envAllowlist),
      bashStepExtraStripPatterns: List.unmodifiable(bashStepPolicy.extraStripPatterns),
      uuid: uuid,
      run: run,
      definition: definition,
      workflowContext: workflowContext,
    );
  }

  StepExecutionContext scoped({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowContext workflowContext,
  }) {
    return StepExecutionContext(
      taskService: taskService,
      eventBus: eventBus,
      kvService: kvService,
      repository: repository,
      gateEvaluator: gateEvaluator,
      contextExtractor: contextExtractor,
      turnAdapter: turnAdapter,
      outputTransformer: outputTransformer,
      skillIntrospector: skillIntrospector,
      providerAuthPreflight: providerAuthPreflight,
      skillPreflightConfig: skillPreflightConfig,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionTransactor: executionTransactor,
      projectService: projectService,
      defaultWorkspaceRoot: defaultWorkspaceRoot,
      dataDir: dataDir,
      templateEngine: templateEngine,
      workflowGitPort: workflowGitPort,
      skillPromptBuilder: skillPromptBuilder,
      roleDefaults: roleDefaults,
      hostEnvironment: hostEnvironment,
      bashStepEnvAllowlist: bashStepEnvAllowlist,
      bashStepExtraStripPatterns: bashStepExtraStripPatterns,
      uuid: uuid,
      run: run,
      definition: definition,
      workflowContext: workflowContext,
    );
  }
}

final class StepPromptConfiguration {
  final WorkflowTemplateEngine templateEngine;
  final SkillPromptBuilder skillPromptBuilder;

  StepPromptConfiguration({
    WorkflowTemplateEngine? templateEngine,
    SkillPromptBuilder? skillPromptBuilder,
    PromptAugmenter? promptAugmenter,
    HarnessFactory? harnessFactory,
  }) : templateEngine = templateEngine ?? WorkflowTemplateEngine(),
       skillPromptBuilder =
           skillPromptBuilder ??
           SkillPromptBuilder(
             augmenter: promptAugmenter ?? const PromptAugmenter(),
             harnessFactory: (harnessFactory ?? HarnessFactory())..warnIfEmpty(context: 'WorkflowExecutor'),
           );
}

final class BashStepPolicy {
  static const defaultEnvAllowlist = <String>[
    'PATH',
    'HOME',
    'LANG',
    'LC_*',
    'TZ',
    'USER',
    'SHELL',
    'TERM',
    'TMPDIR',
    'TMP',
    'TEMP',
  ];

  final Map<String, String>? hostEnvironment;
  final List<String> envAllowlist;
  final List<String> extraStripPatterns;

  const BashStepPolicy({
    this.hostEnvironment,
    this.envAllowlist = defaultEnvAllowlist,
    this.extraStripPatterns = const <String>[],
  });
}
