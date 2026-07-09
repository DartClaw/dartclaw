import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task, WorkflowTaskService;
import 'package:path/path.dart' as p;

/// Reads and formats a task's `diff.json` artifact, if present.
Future<String?> readDiffArtifactSummary(WorkflowTaskService taskService, String dataDir, Task task) async {
  try {
    final artifacts = await taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (!artifact.path.endsWith('diff.json')) continue;
      final raw = await _readArtifactContent(dataDir, task.id, artifact.path);
      if (raw == null) return null;
      return formatDiffArtifactSummary(raw);
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Formats a `diff.json` payload as a compact summary.
String formatDiffArtifactSummary(String raw) {
  try {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final files = (json['files'] as int?) ?? 0;
    final additions = (json['additions'] as int?) ?? 0;
    final deletions = (json['deletions'] as int?) ?? 0;
    return '$files files changed, +$additions -$deletions';
  } catch (_) {
    return raw;
  }
}

Future<String?> _readArtifactContent(String dataDir, String taskId, String path) async {
  try {
    final file = File(p.isAbsolute(path) ? path : p.join(dataDir, 'tasks', taskId, 'artifacts', path));
    if (!file.existsSync()) return null;
    return await file.readAsString();
  } catch (_) {
    return null;
  }
}
