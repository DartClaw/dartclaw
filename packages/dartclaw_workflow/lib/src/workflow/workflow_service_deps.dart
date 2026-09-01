import 'dart:async' show FutureOr;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService, TaskRepository;
import 'package:uuid/uuid.dart';

import '../skills/provider_auth_preflight.dart';
import 'skill_introspector.dart';
import 'step_config_resolver.dart';
import 'workflow_git_port.dart';
import 'workflow_run.dart' show WorkflowWorktreeBinding;
import 'context_extractor.dart' show StructuredOutputFallbackRecorder;

/// Persistence collaborators required to spawn workflow-owned tasks.
final class WorkflowPersistencePorts {
  final TaskRepository taskRepository;
  final AgentExecutionRepository agentExecutionRepository;
  final WorkflowStepExecutionRepository workflowStepExecutionRepository;
  final ExecutionRepositoryTransactor executionRepositoryTransactor;

  const new({
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
  final String? defaultWorkspaceRoot;
  final FutureOr<void> Function(WorkflowWorktreeBinding binding)? hydrateBinding;

  const new({required this.gitPort, this.projectService, this.defaultWorkspaceRoot, this.hydrateBinding});
}

/// Optional runtime customizations for workflow lifecycle management.
final class WorkflowServiceOptions {
  final WorkflowRoleDefaults roleDefaults;
  final WorkflowApprovalPolicy approvalPolicyDefault;
  final StructuredOutputFallbackRecorder? structuredOutputFallbackRecorder;
  final SkillIntrospector? skillIntrospector;
  final ProviderAuthPreflight? providerAuthPreflight;
  final WorkflowSkillPreflightConfig skillPreflightConfig;
  final Map<String, String>? hostEnvironment;
  final List<String>? bashStepEnvAllowlist;
  final List<String>? bashStepExtraStripPatterns;
  final Uuid? uuid;

  const new({
    this.roleDefaults = const WorkflowRoleDefaults(),
    this.approvalPolicyDefault = WorkflowApprovalPolicy.manual,
    this.structuredOutputFallbackRecorder,
    this.skillIntrospector,
    this.providerAuthPreflight,
    this.skillPreflightConfig = const WorkflowSkillPreflightConfig(),
    this.hostEnvironment,
    this.bashStepEnvAllowlist,
    this.bashStepExtraStripPatterns,
    this.uuid,
  });
}
