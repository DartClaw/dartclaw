import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Captures audit entries in memory instead of writing an NDJSON partition.
class RecordingGuardAuditLogger extends GuardAuditLogger {
  final entries = <AuditEntry>[];

  @override
  Future<void> writeEntry(AuditEntry entry) async => entries.add(entry);
}
