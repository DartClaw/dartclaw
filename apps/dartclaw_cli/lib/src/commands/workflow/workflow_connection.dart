import 'package:args/args.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WriteLine, ExitFn;

typedef WorkflowConnectionContext = ({
  ArgResults? globalResults,
  DartclawConfig? config,
  WriteLine writeLine,
  WriteLine stderrLine,
  ExitFn exitFn,
  String prefix,
});

abstract interface class WorkflowConnection {
  Future<void> status(WorkflowConnectionContext context, String runId, void Function(Map<String, dynamic>) onResult);
  Future<void> definition(
    WorkflowConnectionContext context,
    String name, {
    required bool resolved,
    required String? stepId,
    required void Function(String) onResult,
  });
  Future<void> runAction(
    WorkflowConnectionContext context,
    String runId,
    String pathSuffix,
    void Function(Map<String, dynamic>) onResult,
  );
  Future<void> cancel(
    WorkflowConnectionContext context,
    String runId,
    String? feedback,
    void Function(Map<String, dynamic>) onResult,
  );
  Future<void> run(
    WorkflowConnectionContext context, {
    required String workflowName,
    required Map<String, String> variables,
    required String? projectId,
    required WorkflowApprovalPolicy? approvals,
    required bool allowDirtyLocalPath,
    required bool inline,
    required bool jsonOutput,
    required Stream<void> Function() interrupts,
  });
}
