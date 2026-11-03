import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../storage/atomic_write.dart';

/// What a [ThreadBinding] ties its thread to.
enum ThreadBindingKind {
  /// A DartClaw task: inbound messages in the thread route to its session.
  task,

  /// A workflow run: the thread is where the run posts, and routes nothing.
  run,
}

/// An immutable record binding a channel thread to a DartClaw task or workflow run.
///
/// The binding maps a `(channelType, threadId)` pair to a target. A task binding
/// also carries the session key [ChannelTaskBridge] routes the thread's messages
/// to, instead of the default session derivation; a run binding carries none.
class ThreadBinding {
  /// The channel type name (e.g., `'googlechat'`).
  final String channelType;

  /// The thread identity the channel's declared capability reads from an inbound
  /// message in the thread (e.g., `'spaces/AAAA/threads/CCCC'`).
  final String threadId;

  /// Whether [targetId] names a task or a run.
  final ThreadBindingKind kind;

  /// The task ID or run ID this thread is bound to.
  final String targetId;

  /// The session key for the task's agent session; `null` for a run binding.
  final String? sessionKey;

  /// When the binding was created.
  final DateTime createdAt;

  /// When a message was last routed through this binding.
  final DateTime lastActivity;

  /// Creates a binding of [kind].
  const new _({
    required this.channelType,
    required this.threadId,
    required this.kind,
    required this.targetId,
    required this.sessionKey,
    required this.createdAt,
    required this.lastActivity,
  });

  /// Creates a binding that routes the thread to the session of [taskId].
  const new task({
    required String channelType,
    required String threadId,
    required String taskId,
    required String sessionKey,
    required DateTime createdAt,
    required DateTime lastActivity,
  }) : this._(
         channelType: channelType,
         threadId: threadId,
         kind: ThreadBindingKind.task,
         targetId: taskId,
         sessionKey: sessionKey,
         createdAt: createdAt,
         lastActivity: lastActivity,
       );

  /// Creates a binding that holds the thread a run posts into.
  const new run({
    required String channelType,
    required String threadId,
    required String runId,
    required DateTime createdAt,
    required DateTime lastActivity,
  }) : this._(
         channelType: channelType,
         threadId: threadId,
         kind: ThreadBindingKind.run,
         targetId: runId,
         sessionKey: null,
         createdAt: createdAt,
         lastActivity: lastActivity,
       );

  /// Compound in-memory key for this binding.
  static String key(String channelType, String threadId) => '$channelType::$threadId';

  /// Returns a new binding with [lastActivity] updated.
  ThreadBinding copyWith({DateTime? lastActivity}) {
    return ThreadBinding._(
      channelType: channelType,
      threadId: threadId,
      kind: kind,
      targetId: targetId,
      sessionKey: sessionKey,
      createdAt: createdAt,
      lastActivity: lastActivity ?? this.lastActivity,
    );
  }

  /// Serializes to a JSON map with ISO 8601 timestamps.
  ///
  /// A task binding keeps the `taskId` key every earlier row used; a run
  /// binding is keyed `runId`.
  Map<String, dynamic> toJson() => {
    'channelType': channelType,
    'threadId': threadId,
    'kind': kind.name,
    switch (kind) {
      ThreadBindingKind.task => 'taskId',
      ThreadBindingKind.run => 'runId',
    }: targetId,
    'sessionKey': ?sessionKey,
    'createdAt': createdAt.toIso8601String(),
    'lastActivity': lastActivity.toIso8601String(),
  };

  /// Deserializes from a JSON map. A row without a `kind` reads as a task binding.
  factory fromJson(Map<String, dynamic> json) {
    final channelType = json['channelType'] as String;
    final threadId = json['threadId'] as String;
    final createdAt = DateTime.parse(json['createdAt'] as String);
    final lastActivity = DateTime.parse(json['lastActivity'] as String);
    return switch (json['kind']) {
      null || 'task' => ThreadBinding.task(
        channelType: channelType,
        threadId: threadId,
        taskId: json['taskId'] as String,
        sessionKey: json['sessionKey'] as String,
        createdAt: createdAt,
        lastActivity: lastActivity,
      ),
      'run' => ThreadBinding.run(
        channelType: channelType,
        threadId: threadId,
        runId: json['runId'] as String,
        createdAt: createdAt,
        lastActivity: lastActivity,
      ),
      final other => throw FormatException('Unknown thread binding kind "$other"'),
    };
  }
}

/// Persisted store for [ThreadBinding] records.
///
/// In-memory [Map] backed by a JSON file. CRUD operations update the in-memory
/// state and atomically persist to disk. All lookups are synchronous
/// (in-memory); only writes touch the file system.
class ThreadBindingStore {
  static final _log = Logger('ThreadBindingStore');

  final File _file;
  final Map<String, ThreadBinding> _bindings = {};

  /// Creates a store backed by [file].
  new(File file) : _file = file;

  /// Loads existing bindings from [_file].
  ///
  /// Every well-formed row is kept, whichever channels are registered by now: a
  /// row nothing can resolve is retired by the idle sweep or [reconcile], never
  /// here. If the file does not exist or contains invalid JSON, starts with an
  /// empty map and logs a warning.
  Future<void> load() async {
    if (!_file.existsSync()) {
      _log.fine('Thread bindings file not found — starting empty');
      return;
    }

    try {
      final content = await _file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! List) {
        _log.warning('Thread bindings file is not a JSON array — starting empty');
        return;
      }
      for (final entry in decoded) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          final binding = ThreadBinding.fromJson(entry);
          _bindings[ThreadBinding.key(binding.channelType, binding.threadId)] = binding;
        } catch (e) {
          _log.warning('Skipping malformed thread binding entry: $e');
        }
      }
      _log.fine('Loaded ${_bindings.length} thread binding(s)');
    } on FormatException catch (e) {
      _log.warning('Thread bindings file contains invalid JSON — starting empty: $e');
    } on Exception catch (e) {
      _log.warning('Failed to load thread bindings — starting empty: $e');
    }
  }

  /// Creates or overwrites a binding. Persists immediately.
  Future<void> create(ThreadBinding binding) async {
    _bindings[ThreadBinding.key(binding.channelType, binding.threadId)] = binding;
    await _persist();
  }

  /// Returns the binding for [channelType] + [threadId], or `null`.
  ThreadBinding? lookupByThread(String channelType, String threadId) {
    return _bindings[ThreadBinding.key(channelType, threadId)];
  }

  /// Returns all task bindings whose target is [taskId].
  List<ThreadBinding> lookupByTask(String taskId) => _lookupByTarget(ThreadBindingKind.task, taskId);

  /// Returns all run bindings whose target is [runId].
  List<ThreadBinding> lookupByRun(String runId) => _lookupByTarget(ThreadBindingKind.run, runId);

  List<ThreadBinding> _lookupByTarget(ThreadBindingKind kind, String targetId) {
    return _bindings.values
        .where((binding) => binding.kind == kind && binding.targetId == targetId)
        .toList(growable: false);
  }

  /// Updates [lastActivity] for the given thread. No-op if not found.
  Future<void> updateLastActivity(String channelType, String threadId, DateTime timestamp) async {
    final k = ThreadBinding.key(channelType, threadId);
    final existing = _bindings[k];
    if (existing == null) return;
    _bindings[k] = existing.copyWith(lastActivity: timestamp);
    await _persist();
  }

  /// Removes the binding for [channelType] + [threadId]. Persists immediately.
  Future<void> delete(String channelType, String threadId) async {
    _bindings.remove(ThreadBinding.key(channelType, threadId));
    await _persist();
  }

  /// Removes all task bindings for [taskId]. Persists before returning.
  ///
  /// Returns the removed bindings, or an empty list if none existed.
  Future<List<ThreadBinding>> deleteByTaskId(String taskId) => deleteByTarget(ThreadBindingKind.task, taskId);

  /// Removes all bindings of [kind] for [targetId]. Persists before returning.
  ///
  /// Returns the removed bindings, or an empty list if none existed.
  Future<List<ThreadBinding>> deleteByTarget(ThreadBindingKind kind, String targetId) async {
    final removed = <ThreadBinding>[];
    _bindings.removeWhere((_, binding) {
      if (binding.kind == kind && binding.targetId == targetId) {
        removed.add(binding);
        return true;
      }
      return false;
    });
    if (removed.isNotEmpty) await _persist();
    return removed;
  }

  /// Removes task bindings whose [ThreadBinding.lastActivity] is before [cutoff].
  ///
  /// Run bindings are exempt: a run's thread lives as long as the run, which can
  /// sit at an approval for longer than any idle timeout. Persists before
  /// returning if any entries were removed. Returns the list of removed bindings.
  Future<List<ThreadBinding>> removeExpiredBindings(DateTime cutoff) async {
    final expired = <ThreadBinding>[];
    _bindings.removeWhere((_, binding) {
      if (binding.kind == ThreadBindingKind.task && binding.lastActivity.isBefore(cutoff)) {
        expired.add(binding);
        return true;
      }
      return false;
    });
    if (expired.isNotEmpty) await _persist();
    return expired;
  }

  /// Removes bindings whose target is not among [activeTaskIds] or [activeRunIds].
  ///
  /// Persists if any entries were removed. Returns the count of pruned bindings.
  Future<int> reconcile({required Set<String> activeTaskIds, required Set<String> activeRunIds}) async {
    final staleKeys = _bindings.entries
        .where((e) {
          final active = switch (e.value.kind) {
            ThreadBindingKind.task => activeTaskIds,
            ThreadBindingKind.run => activeRunIds,
          };
          return !active.contains(e.value.targetId);
        })
        .map((e) => e.key)
        .toList(growable: false);
    if (staleKeys.isEmpty) return 0;
    for (final k in staleKeys) {
      _bindings.remove(k);
    }
    await _persist();
    return staleKeys.length;
  }

  Future<void> _persist() async {
    final data = _bindings.values.map((b) => b.toJson()).toList(growable: false);
    await atomicWriteJson(_file, data);
  }
}
