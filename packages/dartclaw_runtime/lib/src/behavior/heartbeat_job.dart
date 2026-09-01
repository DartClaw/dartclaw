import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../scheduling/scheduled_job.dart';

final _log = Logger('HeartbeatJob');

/// Reserved id of the built-in heartbeat job.
///
/// The live `scheduling.heartbeat.enabled` toggle pauses and resumes this job,
/// so the id is part of the runtime control surface, not a label.
const heartbeatJobId = 'heartbeat';

/// Builds the built-in heartbeat job for [workspaceDir].
///
/// Each fire reads `HEARTBEAT.md` and processes a non-empty checklist in a
/// session unique to that cycle. A missing, empty, or undecodable checklist
/// ends the fire quietly: no turn, no session, no failure, no retry.
ScheduledJob buildHeartbeatJob({required String workspaceDir, required int intervalMinutes}) => ScheduledJob(
  id: heartbeatJobId,
  scheduleType: ScheduleType.interval,
  intervalMinutes: intervalMinutes,
  perFireSession: true,
  promptResolver: () => _readChecklist(workspaceDir),
);

Future<String?> _readChecklist(String workspaceDir) async {
  final String content;
  try {
    content = await File(p.join(workspaceDir, 'HEARTBEAT.md')).readAsString();
  } on FileSystemException {
    _log.fine('No HEARTBEAT.md found — skipping checklist');
    return null;
  } on FormatException catch (e) {
    _log.warning('HEARTBEAT.md has invalid encoding: ${e.message} — skipping checklist');
    return null;
  }
  if (content.trim().isEmpty) {
    _log.fine('HEARTBEAT.md is empty — skipping checklist');
    return null;
  }
  return 'Process this checklist:\n\n$content';
}
