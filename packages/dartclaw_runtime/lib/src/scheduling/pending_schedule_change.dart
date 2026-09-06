import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Whether a parked upsert would add a new `scheduling.jobs` entry or replace
/// the one its id already names.
enum PendingChangeKind { created, replaced }

/// A `schedule_upsert` write the seam validated but did not commit.
///
/// Everything except [changeId] and [requestedAt] originated in a model turn,
/// so a renderer treats every field as untrusted text.
final class PendingScheduleChange {
  const new({
    required this.changeId,
    required this.jobId,
    required this.kind,
    required this.job,
    required this.requester,
    required this.requestedAt,
  });

  final String changeId;
  final String jobId;
  final PendingChangeKind kind;

  /// The validated job body exactly as the seam would have written it.
  final Map<String, dynamic> job;

  /// Host-owned provenance: the MCP caller's authority id, or the tool name
  /// where the dispatch carried no identity.
  final String requester;
  final DateTime requestedAt;

  Map<String, dynamic> toJson() => {
    'changeId': changeId,
    'jobId': jobId,
    'kind': kind.name,
    'job': job,
    'requester': requester,
    'requestedAt': requestedAt.toUtc().toIso8601String(),
  };

  factory fromJson(Map<String, dynamic> json) {
    final job = Map<String, dynamic>.from(json['job'] as Map);
    // The one nested key every later read dereferences unguarded.
    if (job['id'] is! String) throw const FormatException('job.id must be a string');
    return PendingScheduleChange(
      changeId: json['changeId'] as String,
      jobId: json['jobId'] as String,
      kind: PendingChangeKind.values.byName(json['kind'] as String),
      job: job,
      requester: json['requester'] as String,
      requestedAt: DateTime.parse(json['requestedAt'] as String),
    );
  }
}

/// The one data-dir side-state for parked schedule writes.
///
/// In-memory map backed by `<data_dir>/pending-schedule-changes.json`; every
/// write persists atomically, lookups are synchronous. A record only exists
/// here between the parked tool call and the operator's approve or reject, so
/// there is no schema version and no migration.
class PendingScheduleChangeStore {
  static final _log = Logger('PendingScheduleChangeStore');

  final File _file;
  final Map<String, PendingScheduleChange> _changes = {};

  new(File file) : _file = file;

  /// Loads the persisted records.
  ///
  /// An unreadable file starts empty with a warning, and an entry that does not
  /// deserialize is skipped with a warning naming it while the rest load —
  /// losing a parked change silently is what the warning prevents. A missing
  /// file is the normal first boot and is not warned about.
  Future<void> load() async {
    if (!_file.existsSync()) {
      _log.fine('Pending schedule changes file not found — starting empty');
      return;
    }
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! List) {
        _log.warning('Pending schedule changes file is not a JSON array — starting empty');
        return;
      }
      for (final entry in decoded) {
        try {
          final change = PendingScheduleChange.fromJson(Map<String, dynamic>.from(entry as Map));
          _changes[change.changeId] = change;
        } catch (e) {
          _log.warning('Skipping malformed pending schedule change entry $entry: $e');
        }
      }
    } catch (e) {
      _log.warning('Failed to load pending schedule changes — starting empty: $e');
    }
  }

  /// Every parked change, oldest request first.
  List<PendingScheduleChange> get values =>
      _changes.values.toList()..sort((a, b) => a.requestedAt.compareTo(b.requestedAt));

  PendingScheduleChange? byId(String changeId) => _changes[changeId];

  Future<void> add(PendingScheduleChange change) async {
    _changes[change.changeId] = change;
    await _persist();
  }

  Future<void> remove(String changeId) async {
    if (_changes.remove(changeId) == null) return;
    await _persist();
  }

  Future<void> _persist() => atomicWriteJson(_file, [for (final change in values) change.toJson()]);
}
