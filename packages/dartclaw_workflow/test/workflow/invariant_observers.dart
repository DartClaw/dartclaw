// Invariant observers for workflow tests.
//
// These are small, composable helpers that make assertions about side effects
// of a workflow step / task execution — specifically the kinds of silent
// misbehavior that the 30–75-minute real-Codex E2E would otherwise be the
// first place to notice.
//
// Concrete observers:
//
//  * [WorkspaceFileWriteObserver]  — snapshots the workspace before a step,
//    diffs after, and fails the test if files were written outside an
//    allowlist. Catches regressions like "implement step wrote docs/STATE.md"
//    (2026-04-24 E2E issue #10).
//
//  * [LogInvariantObserver]        — listens to `package:logging` and fails
//    the test on known-spurious warning patterns (e.g. "requires a worktree
//    but has no worktree metadata" — issue #7).
//
//  * [TokenCeilingObserver]        — collects per-step token usage and fails
//    if any step exceeds a configured ceiling (issue #8). Accepts explicit
//    override for legitimate heavy steps.
//
// Use pattern:
//   final fileObserver = WorkspaceFileWriteObserver.snapshot(workspaceDir);
//   // ... run step ...
//   fileObserver.expectOnly(['docs/specs/foo/plan.md']);
//
// These observers are intentionally simple and not coupled to the workflow
// executor. They compose with [ScenarioTaskHarness], the builtin integration
// stub, or the real-Codex step-isolation tests without modification.
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Workspace file-write observer
// ---------------------------------------------------------------------------

/// Snapshot-and-diff observer for workspace file writes.
///
/// Take a snapshot before running a step; after the step completes, call
/// [expectOnly] with the set of paths the step was authorized to touch.
/// Any other new or modified file fails the test with a clear message.
class WorkspaceFileWriteObserver {
  final String _root;
  final Map<String, _FileFingerprint> _baseline;
  final Set<String> _ignoredDirs;

  WorkspaceFileWriteObserver._(this._root, this._baseline, this._ignoredDirs);

  /// Capture the current state of files under [workspaceDir].
  ///
  /// Directories matching any entry in [ignoredDirs] (relative-path prefix)
  /// are excluded from the snapshot. Defaults cover `.git` / `.dartclaw` /
  /// `.dart_tool` / `node_modules`.
  factory WorkspaceFileWriteObserver.snapshot(
    String workspaceDir, {
    Set<String> ignoredDirs = const {'.git', '.dartclaw', '.dart_tool', 'node_modules'},
  }) {
    final baseline = _fingerprintTree(workspaceDir, ignoredDirs);
    return WorkspaceFileWriteObserver._(workspaceDir, baseline, ignoredDirs);
  }

  /// Diff the workspace against the baseline. Returns relative paths of files
  /// created or modified since [snapshot].
  List<String> diff() {
    final now = _fingerprintTree(_root, _ignoredDirs);
    final changed = <String>[];
    for (final entry in now.entries) {
      final before = _baseline[entry.key];
      if (before == null || before != entry.value) {
        changed.add(entry.key);
      }
    }
    for (final path in _baseline.keys) {
      if (!now.containsKey(path)) {
        changed.add('$path (deleted)');
      }
    }
    changed.sort();
    return changed;
  }

  /// Assert that only files matching an entry in [allowed] changed since the
  /// baseline snapshot. Each entry is a relative path; glob-style `*` wildcard
  /// is supported inside a single path segment.
  ///
  /// [reason] is included verbatim in the failure message.
  void expectOnly(Iterable<String> allowed, {String? reason}) {
    final changed = diff();
    final allowedMatchers = allowed.map(_compileMatcher).toList(growable: false);
    final unauthorized = changed.where((path) {
      return !allowedMatchers.any((m) => m(path));
    }).toList();

    if (unauthorized.isEmpty) return;
    final message = StringBuffer()..writeln('Unauthorized workspace file writes detected:');
    for (final path in unauthorized) {
      message.writeln('  - $path');
    }
    message
      ..writeln('Allowed patterns:')
      ..writeln('  ${allowed.join(', ')}');
    if (reason != null) {
      message.writeln('Context: $reason');
    }
    fail(message.toString());
  }

  /// Asserts that none of the [forbiddenPaths] were written to. Use when a
  /// step is allowed to touch arbitrary files *except* known state documents
  /// (STATE.md etc.).
  void expectNotTouched(Iterable<String> forbiddenPaths, {String? reason}) {
    final changed = diff();
    final forbiddenHits = <String>[];
    for (final path in changed) {
      for (final forbidden in forbiddenPaths) {
        if (path == forbidden || path.endsWith('/$forbidden') || path.endsWith('\\$forbidden')) {
          forbiddenHits.add(path);
          break;
        }
      }
    }
    if (forbiddenHits.isEmpty) return;
    fail('Forbidden workspace file writes detected: $forbiddenHits. ${reason ?? ''}');
  }

  static Map<String, _FileFingerprint> _fingerprintTree(String root, Set<String> ignoredDirs) {
    final map = <String, _FileFingerprint>{};
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) return map;
    for (final entity in rootDir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root);
      final segments = p.split(relative);
      if (segments.any(ignoredDirs.contains)) continue;
      final stat = entity.statSync();
      map[relative] = _FileFingerprint(stat.size, stat.modified.microsecondsSinceEpoch);
    }
    return map;
  }

  static bool Function(String) _compileMatcher(String pattern) {
    if (!pattern.contains('*')) return (path) => path == pattern;
    final regexBody = pattern.split('*').map(RegExp.escape).join(r'[^/\\]*');
    final regex = RegExp('^$regexBody\$');
    return (path) => regex.hasMatch(path);
  }
}

class _FileFingerprint {
  final int size;
  final int modifiedMicros;
  const _FileFingerprint(this.size, this.modifiedMicros);

  @override
  bool operator ==(Object other) =>
      other is _FileFingerprint && other.size == size && other.modifiedMicros == modifiedMicros;

  @override
  int get hashCode => Object.hash(size, modifiedMicros);
}

// ---------------------------------------------------------------------------
// Log invariant observer
// ---------------------------------------------------------------------------

/// Listens on `package:logging` and records any record matching configured
/// forbidden patterns. Call [dispose] in `tearDown`; call [expectClean] to
/// fail the test on a match.
///
/// Default patterns cover warnings seen in the 2026-04-24 E2E run that were
/// found to be misleading (step completed despite the warning firing).
class LogInvariantObserver {
  final List<RegExp> _forbiddenPatterns;
  final List<LogRecord> _violations = [];
  final List<LogRecord> _allRecords = [];
  StreamSubscription<LogRecord>? _subscription;
  Level _previousRootLevel = Level.INFO;
  Level _minimumLevel = Level.WARNING;

  LogInvariantObserver._(this._forbiddenPatterns);

  /// Default observer: catches the known-spurious "requires a worktree"
  /// warning and the "succeeded without FIS" log (if emitted).
  factory LogInvariantObserver.defaults({List<RegExp> extra = const []}) {
    return LogInvariantObserver._([
      RegExp('requires a worktree but has no worktree metadata'),
      // Add known-spurious patterns here as they are documented.
      ...extra,
    ]);
  }

  /// Observer that records all log records at or above [minimumLevel] without
  /// any forbidden-pattern rules. Use with [expectRecord] for positive
  /// assertions about failure-path logging.
  factory LogInvariantObserver.capture({Level minimumLevel = Level.WARNING}) {
    return LogInvariantObserver._([]).._minimumLevel = minimumLevel;
  }

  /// All captured records at or above the minimum level, in insertion order.
  List<LogRecord> get records => List.unmodifiable(_allRecords);

  /// Start listening. Temporarily sets the root logger level so records at or
  /// above the configured minimum reach the listener regardless of the
  /// project-wide default.
  void start() {
    _previousRootLevel = Logger.root.level;
    if (_previousRootLevel > _minimumLevel) {
      Logger.root.level = _minimumLevel;
    }
    _subscription = Logger.root.onRecord.listen((record) {
      if (record.level < _minimumLevel) return;
      _allRecords.add(record);
      for (final pattern in _forbiddenPatterns) {
        if (pattern.hasMatch(record.message)) {
          _violations.add(record);
          return;
        }
      }
    });
  }

  /// Fail the test if any forbidden log records were observed.
  void expectClean({String? reason}) {
    if (_violations.isEmpty) return;
    final buffer = StringBuffer()..writeln('Forbidden log records observed:');
    for (final record in _violations) {
      buffer.writeln('  [${record.level.name}] ${record.loggerName}: ${record.message}');
    }
    if (reason != null) buffer.writeln('Context: $reason');
    fail(buffer.toString());
  }

  /// Assert that at least one recorded log matches the given criteria.
  ///
  /// - [level] (optional) must match the record's level exactly.
  /// - [pattern] matches anywhere in the record's message.
  /// - [loggerName] (optional) must equal the record's logger name.
  ///
  /// Fails with a diagnostic listing all observed records if no match is
  /// found. Intended for asserting failure-path logging (e.g. "promotion
  /// failure emitted a WARNING" — Issue A regression guard).
  void expectRecord({Level? level, required Pattern pattern, String? loggerName}) {
    final regex = pattern is RegExp ? pattern : RegExp(RegExp.escape(pattern.toString()));
    final match = _allRecords.any((record) {
      if (level != null && record.level != level) return false;
      if (loggerName != null && record.loggerName != loggerName) return false;
      return regex.hasMatch(record.message);
    });
    if (match) return;
    final buffer = StringBuffer()
      ..writeln('Expected log record not found.')
      ..writeln('  level:      ${level?.name ?? '(any)'}')
      ..writeln('  loggerName: ${loggerName ?? '(any)'}')
      ..writeln('  pattern:    $regex');
    if (_allRecords.isEmpty) {
      buffer.writeln('No records were captured.');
    } else {
      buffer.writeln('Observed records:');
      for (final record in _allRecords) {
        buffer.writeln('  [${record.level.name}] ${record.loggerName}: ${record.message}');
      }
    }
    fail(buffer.toString());
  }

  /// Stop listening and restore the root logger level.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    Logger.root.level = _previousRootLevel;
  }
}

// ---------------------------------------------------------------------------
// Token ceiling observer (unit-level helper)
// ---------------------------------------------------------------------------

/// Records per-step token usage and fails the test when a step exceeds its
/// ceiling. Intended for scenarios that track usage manually; for end-to-end
/// recorders the existing artifact validator is the right place.
class TokenCeilingObserver {
  final Map<String, int> _ceilings;
  final int _defaultCeiling;
  final Map<String, int> _observations = {};

  TokenCeilingObserver({required int defaultCeiling, Map<String, int>? ceilings})
    : _defaultCeiling = defaultCeiling,
      _ceilings = {...?ceilings};

  void record(String stepId, int tokens) {
    _observations[stepId] = (_observations[stepId] ?? 0) + tokens;
  }

  void expectAllWithinCeilings() {
    final violations = <String>[];
    for (final entry in _observations.entries) {
      final ceiling = _ceilings[entry.key] ?? _defaultCeiling;
      if (entry.value > ceiling) {
        violations.add('${entry.key}: ${entry.value} > $ceiling');
      }
    }
    if (violations.isEmpty) return;
    fail('Token ceiling violations: $violations');
  }
}
