import 'dart:io';

import '../safe_process.dart';
import 'inline_process_environment_plan.dart';

/// Signature of the canonical git runner, and the one injectable test seam
/// production code accepts for git spawning.
typedef GitRunner = Future<ProcessResult> Function(
  List<String> arguments, {
  String? workingDirectory,
  ProcessEnvironmentPlan plan,
  bool noSystemConfig,
});

/// Runs `git` with [arguments] — the single production entry point for git
/// subprocesses across the workspace.
///
/// [noSystemConfig] defaults to `true` because automation-owned git paths
/// check out, stage and commit: system-level git config (hooks, filter
/// drivers, `core.sshCommand`) would otherwise run in-band inside DartClaw's
/// own worktrees. Call sites that are user-visible git or that need system
/// transport config to work at all pass `noSystemConfig: false` explicitly and
/// name the classification, per the automation-owned vs user-visible split in
/// `dev/architecture/security-architecture.md`.
///
/// [plan] overlays credential environment onto the sanitized git base
/// environment; it defaults to the empty overlay.
Future<ProcessResult> runGit(
  List<String> arguments, {
  String? workingDirectory,
  ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
  bool noSystemConfig = true,
}) {
  return SafeProcess.git(arguments, plan: plan, workingDirectory: workingDirectory, noSystemConfig: noSystemConfig);
}
