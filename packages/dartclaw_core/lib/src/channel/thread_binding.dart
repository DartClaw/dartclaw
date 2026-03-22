import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';

import '../storage/atomic_write.dart';
import 'channel.dart';

/// An immutable record binding a Google Chat thread to a DartClaw task session.
///
/// The binding maps a `(channelType, threadId)` pair to a `(taskId, sessionKey)`.
/// Used by [ChannelTaskBridge] to route messages from a bound thread directly
/// to the task's session rather than the default session derivation.
class ThreadBinding {
  /// The channel type name (e.g., `'googlechat'`).
  final String channelType;

  /// The server-assigned thread resource name (e.g., `'spaces/AAAA/threads/CCCC'`).
  final String threadId;

  /// The task ID this thread is bound to.
  final String taskId;

  /// The session key for the task's agent session.
  final String sessionKey;

  /// When the binding was created.
  final DateTime createdAt;

  /// When a message was last routed through this binding.
  final DateTime lastActivity;

  /// Creates a thread binding.
  const ThreadBinding({
    required this.channelType,
    required this.threadId,
    required this.taskId,
    required this.sessionKey,
    required this.createdAt,
    required this.lastActivity,
  });

  /// Compound in-memory key for this binding.
  static String key(String channelType, String threadId) => '$channelType::$threadId';

  /// Returns a new binding with [lastActivity] updated.
  ThreadBinding copyWith({DateTime? lastActivity}) {
    return ThreadBinding(
      channelType: channelType,
      threadId: threadId,
      taskId: taskId,
      sessionKey: sessionKey,
      createdAt: createdAt,
      lastActivity: lastActivity ?? this.lastActivity,
    );
  }

  /// Serializes to a JSON map with ISO 8601 timestamps.
  Map<String, dynamic> toJson() => {
        'channelType': channelType,
        'threadId': threadId,
        'taskId': taskId,
        'sessionKey': sessionKey,
        'createdAt': createdAt.toIso8601String(),
        'lastActivity': lastActivity.toIso8601String(),
      };

  /// Deserializes from a JSON map.
  factory ThreadBinding.fromJson(Map<String, dynamic> json) {
    return ThreadBinding(
      channelType: json['channelType'] as String,
      threadId: json['threadId'] as String,
      taskId: json['taskId'] as String,
      sessionKey: json['sessionKey'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastActivity: DateTime.parse(json['lastActivity'] as String),
    );
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
  ThreadBindingStore(File file) : _file = file;

  /// Loads existing bindings from [_file].
  ///
  /// If the file does not exist or contains invalid JSON, starts with an empty
  /// map and logs a warning.
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

  /// Returns the binding whose [ThreadBinding.taskId] matches [taskId], or `null`.
  ThreadBinding? lookupByTask(String taskId) {
    return _bindings.values.firstWhereOrNull((b) => b.taskId == taskId);
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

  /// Removes the binding for [taskId], if any. Persists immediately.
  ///
  /// Returns the removed binding, or `null` if no binding existed for [taskId].
  ThreadBinding? deleteByTaskId(String taskId) {
    final key = _bindings.keys.firstWhereOrNull((k) => _bindings[k]!.taskId == taskId);
    if (key == null) return null;
    final removed = _bindings.remove(key);
    // Best-effort persist — in-memory state is already updated.
    // ignore: unawaited_futures
    _persist().catchError((Object e, StackTrace st) => _log.warning('Failed to persist binding deletion for task $taskId', e, st));
    return removed;
  }

  /// Removes all bindings whose [ThreadBinding.lastActivity] is before [cutoff].
  ///
  /// Persists if any entries were removed. Returns the list of removed bindings.
  List<ThreadBinding> removeExpiredBindings(DateTime cutoff) {
    final expired = <ThreadBinding>[];
    _bindings.removeWhere((_, binding) {
      if (binding.lastActivity.isBefore(cutoff)) {
        expired.add(binding);
        return true;
      }
      return false;
    });
    // Best-effort persist — in-memory state is already updated.
    if (expired.isNotEmpty) {
      // ignore: unawaited_futures
      _persist().catchError((Object e, StackTrace st) => _log.warning('Failed to persist expired binding removal', e, st));
    }
    return expired;
  }

  /// Removes bindings whose [ThreadBinding.taskId] is not in [activeTaskIds].
  ///
  /// Persists if any entries were removed. Returns the count of pruned bindings.
  Future<int> reconcile(Set<String> activeTaskIds) async {
    final staleKeys = _bindings.entries
        .where((e) => !activeTaskIds.contains(e.value.taskId))
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

/// Extracts the Google Chat thread name from a [ChannelMessage]'s metadata.
///
/// Returns `metadata['threadName']` when present and non-empty, otherwise `null`.
String? extractThreadId(ChannelMessage message) {
  final threadName = message.metadata['threadName'];
  if (threadName is String && threadName.isNotEmpty) return threadName;
  return null;
}
