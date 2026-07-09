import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show atomicWriteJson;

import 'workflow_context.dart';
import 'workflow_run_paths.dart';

Future<void> persistWorkflowContext({
  required String dataDir,
  required String runId,
  required WorkflowContext context,
}) async {
  final file = File(workflowRunContextJson(dataDir: dataDir, runId: runId));
  await file.parent.create(recursive: true);
  await atomicWriteJson(file, context.toJson());
}
