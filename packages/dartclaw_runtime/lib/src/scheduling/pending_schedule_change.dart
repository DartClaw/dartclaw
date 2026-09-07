import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Whether a parked upsert would add a new `scheduling.jobs` entry or replace
/// the one its id already names.
enum PendingChangeKind { created, replaced }

/// Raised when parking another change would exceed the durable queue bound.
final class PendingScheduleChangeCapacityExceeded implements Exception {
  const new();

  @override
  String toString() =>
      'Pending schedule approval queue is full (${PendingScheduleChangeStore.maxEntries} entries or '
      '${PendingScheduleChangeStore.maxBytes} serialized UTF-8 bytes); '
      'settle an existing change before trying again.';
}

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
    final jobId = job['id'];
    if (jobId is! String || jobId.isEmpty) throw const FormatException('job.id must be a non-empty string');
    if (json['jobId'] != jobId) throw const FormatException('jobId must match job.id');
    if (!const {'prompt', 'task'}.contains(job['type'])) {
      throw const FormatException('job.type must be prompt or task');
    }
    return PendingScheduleChange(
      changeId: json['changeId'] as String,
      jobId: jobId,
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

  /// Maximum number of changes accepted into a queue.
  static const maxEntries = 100;

  /// Maximum compact JSON size accepted into a queue, in UTF-8 bytes.
  static const maxBytes = 1024 * 1024;

  final File _file;
  final Future<void> Function(File, Object) _writeJson;
  final _lock = RepoLock();
  final Map<String, PendingScheduleChange> _changes = {};

  /// Creates a store over [file].
  ///
  /// [writeJson] is injectable to exercise durability failures without
  /// changing the production write authority.
  new(File file, {Future<void> Function(File, Object)? writeJson})
    : _file = file,
      _writeJson = writeJson ?? atomicWriteJson;

  /// Loads the persisted records.
  ///
  /// An unreadable file starts empty with a warning, and an entry that does not
  /// deserialize is skipped with a warning naming it while the rest load —
  /// losing a parked change silently is what the warning prevents. A missing
  /// file is the normal first boot and is not warned about.
  Future<void> load() async {
    await synchronized(() async {
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
        final loaded = <String, PendingScheduleChange>{};
        for (final entry in decoded) {
          try {
            final change = PendingScheduleChange.fromJson(Map<String, dynamic>.from(entry as Map));
            loaded[change.changeId] = change;
          } catch (e) {
            _log.warning('Skipping malformed pending schedule change entry $entry: $e');
          }
        }
        _changes
          ..clear()
          ..addAll(loaded);
        if (_changes.length > maxEntries || _serializedBytes(_changes.values) > maxBytes) {
          _log.warning(
            'Loaded a legacy pending schedule queue over the current $maxEntries-entry or $maxBytes-byte limit; '
            'existing changes remain available for settlement, but new changes are refused until it is within bounds',
          );
        }
      } catch (e) {
        _log.warning('Failed to load pending schedule changes — starting empty: $e');
      }
    });
  }

  /// Every parked change, oldest request first.
  List<PendingScheduleChange> get values =>
      _changes.values.toList()..sort((a, b) => a.requestedAt.compareTo(b.requestedAt));

  PendingScheduleChange? byId(String changeId) => _changes[changeId];

  Future<void> add(PendingScheduleChange change) async {
    await synchronized(() async {
      final updated = {..._changes, change.changeId: change};
      if (updated.length > maxEntries || _serializedBytes(updated.values) > maxBytes) {
        throw const PendingScheduleChangeCapacityExceeded();
      }
      await _persist(updated.values);
      _changes
        ..clear()
        ..addAll(updated);
    });
  }

  Future<void> remove(String changeId) async {
    await synchronized(() async {
      if (!_changes.containsKey(changeId)) return;
      final updated = {..._changes}..remove(changeId);
      await _persist(updated.values);
      _changes
        ..clear()
        ..addAll(updated);
    });
  }

  /// Runs a pending-state transition under this store's durable mutation lock.
  ///
  /// Settlement keeps its lookup, config write and pending removal in this
  /// scope, so two operator decisions cannot both act on the same record.
  Future<T> synchronized<T>(FutureOr<T> Function() action) => _lock.acquire(_file.path, action);

  Future<void> _persist(Iterable<PendingScheduleChange> changes) =>
      _writeJson(_file, [for (final change in _sorted(changes)) change.toJson()]);

  static int _serializedBytes(Iterable<PendingScheduleChange> changes) =>
      utf8.encode(jsonEncode([for (final change in _sorted(changes)) change.toJson()])).length;

  static List<PendingScheduleChange> _sorted(Iterable<PendingScheduleChange> changes) =>
      changes.toList()..sort((a, b) => a.requestedAt.compareTo(b.requestedAt));
}
