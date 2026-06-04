import 'dart:async' show FutureOr;

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentExecutionRepository,
        ExecutionRepositoryTransactor,
        ProjectService,
        TaskRepository,
        WorkflowStepExecutionRepository;
import 'package:uuid/uuid.dart';

import 'skill_introspector.dart';
import 'step_config_resolver.dart';
import 'workflow_git_port.dart';
import 'workflow_run.dart' show WorkflowWorktreeBinding;
import 'workflow_runner_types.dart' show WorkflowStepOutputTransformer;
import 'context_extractor.dart' show StructuredOutputFallbackRecorder;

/// Persistence collaborators required to spawn workflow-owned tasks.
final class WorkflowPersistencePorts {
  final TaskRepository taskRepository;
  final AgentExecutionRepository agentExecutionRepository;
  final WorkflowStepExecutionRepository workflowStepExecutionRepository;
  final ExecutionRepositoryTransactor executionRepositoryTransactor;

  const WorkflowPersistencePorts({
    required this.taskRepository,
    required this.agentExecutionRepository,
    required this.workflowStepExecutionRepository,
    required this.executionRepositoryTransactor,
  });
}

/// Git lifecycle collaborators used by project-backed workflow runs.
final class WorkflowGitContext {
  final WorkflowGitPort gitPort;
  final ProjectService? projectService;
  final FutureOr<void> Function(WorkflowWorktreeBinding binding)? hydrateBinding;

  const WorkflowGitContext({required this.gitPort, this.projectService, this.hydrateBinding});
}

/// Optional runtime customizations for workflow lifecycle management.
final class WorkflowServiceOptions {
  final WorkflowRoleDefaults roleDefaults;
  final WorkflowStepOutputTransformer? outputTransformer;
  final StructuredOutputFallbackRecorder? structuredOutputFallbackRecorder;
  final SkillIntrospector? skillIntrospector;
  final WorkflowSkillPreflightConfig skillPreflightConfig;
  final Map<String, String>? hostEnvironment;
  final List<String>? bashStepEnvAllowlist;
  final List<String>? bashStepExtraStripPatterns;
  final Uuid? uuid;

  const WorkflowServiceOptions({
    this.roleDefaults = const WorkflowRoleDefaults(),
    this.outputTransformer,
    this.structuredOutputFallbackRecorder,
    this.skillIntrospector,
    this.skillPreflightConfig = const WorkflowSkillPreflightConfig(),
    this.hostEnvironment,
    this.bashStepEnvAllowlist,
    this.bashStepExtraStripPatterns,
    this.uuid,
  });
}
