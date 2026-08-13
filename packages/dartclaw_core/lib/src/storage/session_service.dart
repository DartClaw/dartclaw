import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:dartclaw_models/dartclaw_models.dart';

import '../concurrency/repo_lock.dart';
import '../events/dartclaw_event.dart';
import '../events/event_bus.dart';
import 'atomic_write.dart';
import 'uuid_validation.dart';

/// Manages session CRUD operations backed by NDJSON file storage.
class SessionService {
  final String baseDir;
  final EventBus? eventBus;
  final RepoLock _repoLock;
  static const _uuid = Uuid();
  static final _log = Logger('SessionService');

  new({required this.baseDir, this.eventBus, RepoLock? repoLock}) : _repoLock = repoLock ?? RepoLock();

  Future<Session> createSession({
    SessionType type = SessionType.user,
    String? channelKey,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    final id = _uuid.v4();
    final dir = Directory(p.join(baseDir, id));
    await dir.create(recursive: true);

    final now = DateTime.now();
    final session = Session(
      id: id,
      type: type,
      channelKey: channelKey,
      provider: provider,
      securityProfile: securityProfile,
      executionMode: executionMode,
      createdAt: now,
      updatedAt: now,
    );
    await atomicWriteJson(File(p.join(dir.path, 'meta.json')), session.toJson());
    eventBus?.fire(
      SessionCreatedEvent(sessionId: session.id, sessionKey: channelKey, sessionType: type.name, timestamp: now),
    );
    return session;
  }

  /// Ensures exactly one main session exists. Returns it.
  Future<Session> getOrCreateMainSession() async {
    return getOrCreateByKey('main', type: SessionType.main);
  }

  Future<Session?> getSession(String id) async {
    if (!isValidUuid(id)) return null;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;
    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    return Session.fromJson(json);
  }

  Future<List<Session>> listSessions({
    SessionType? type,
    List<SessionType>? types,
    bool includeTaskSessions = false,
  }) async {
    final dir = Directory(baseDir);
    if (!dir.existsSync()) return [];

    final taskRequested = type == SessionType.task || (types?.contains(SessionType.task) ?? false);
    final logicalAgentRequested =
        type == SessionType.logicalAgent || (types?.contains(SessionType.logicalAgent) ?? false);
    final sessions = <Session>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!isValidUuid(name)) continue;
      final metaFile = File(p.join(entity.path, 'meta.json'));
      if (!metaFile.existsSync()) continue;
      try {
        final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final session = Session.fromJson(json);
        if (session.type == SessionType.task && !includeTaskSessions && !taskRequested) continue;
        if (session.type == SessionType.logicalAgent && !logicalAgentRequested) continue;
        if (type != null && session.type != type) continue;
        if (types != null && !types.contains(session.type)) continue;
        sessions.add(session);
      } catch (e) {
        _log.fine('Skipping malformed session dir: $e');
      }
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<int> updateTitle(String id, String title) async {
    if (!isValidUuid(id)) return 0;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return 0;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(title: title, updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
    return 1;
  }

  Future<void> touchUpdatedAt(String id) async {
    if (!isValidUuid(id)) return;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
  }

  /// Creates or retrieves a session by deterministic external key.
  /// Maps external keys (e.g. 'cron:daily-summary') to internal UUID sessions
  /// via a key->UUID index file.
  ///
  /// Serialised with [RepoLock] so concurrent callers (e.g. parallel workflow
  /// foreach iterations each creating their own session) don't interleave the
  /// read-modify-write on `.session_keys.json` and lose each other's mappings.
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    return _repoLock.acquire(
      p.join(baseDir, '.session_keys.json'),
      () => _getOrCreateByKeyLocked(
        key,
        type: type,
        provider: provider,
        securityProfile: securityProfile,
        executionMode: executionMode,
      ),
    );
  }

  /// Returns the active session mapped to [key], without creating one.
  Future<Session?> getByKey(String key) {
    return _repoLock.acquire(p.join(baseDir, '.session_keys.json'), () async {
      final keyIndex = await _readKeyIndex(File(p.join(baseDir, '.session_keys.json')));
      final id = keyIndex[key];
      if (id == null) return null;
      final session = await getSession(id);
      return session == null || session.type == SessionType.archive || session.channelKey != key ? null : session;
    });
  }

  /// Removes the deterministic mapping for [key] without deleting its session.
  Future<void> removeKeyMapping(String key) {
    return _repoLock.acquire(p.join(baseDir, '.session_keys.json'), () async {
      final indexFile = File(p.join(baseDir, '.session_keys.json'));
      final keyIndex = await _readKeyIndex(indexFile);
      if (keyIndex.remove(key) != null) {
        await atomicWriteJson(indexFile, keyIndex);
      }
    });
  }

  Future<Session> _getOrCreateByKeyLocked(
    String key, {
    required SessionType type,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    final indexFile = File(p.join(baseDir, '.session_keys.json'));

    final keyIndex = await _readKeyIndex(indexFile);

    // Check if key already maps to a session
    final existingId = keyIndex[key];
    if (existingId != null) {
      final session = await getSession(existingId);
      if (session != null && session.type != SessionType.archive) {
        // Lazy migration: update type/channelKey if needed (e.g. old sessions without type)
        // A null executionMode argument means "caller has no opinion" — never
        // clear a mode already pinned on disk.
        final resolvedMode = executionMode ?? session.executionMode;
        if (session.type != type ||
            session.channelKey != key ||
            session.provider != provider ||
            session.securityProfile != securityProfile ||
            session.executionMode != resolvedMode) {
          final migrated = session.copyWith(
            type: type,
            channelKey: key,
            provider: provider,
            securityProfile: securityProfile,
            executionMode: resolvedMode,
          );
          await _updateSession(migrated);
          return migrated;
        }
        return session;
      }
      // Stale/archived mapping — remove and create new
      keyIndex.remove(key);
    }

    // Create new session and record mapping
    final session = await createSession(
      type: type,
      channelKey: key,
      provider: provider,
      securityProfile: securityProfile,
      executionMode: executionMode,
    );
    keyIndex[key] = session.id;
    await atomicWriteJson(indexFile, keyIndex);
    return session;
  }

  Future<Map<String, String>> _readKeyIndex(File indexFile) async {
    if (indexFile.existsSync()) {
      try {
        final raw = jsonDecode(await indexFile.readAsString());
        if (raw is Map) return Map<String, String>.from(raw);
      } catch (e) {
        _log.fine('Session key index corrupted or unreadable — using empty index: $e');
      }
    }
    return {};
  }

  /// Updates session type (e.g. archive→user for resume).
  Future<Session?> updateSessionType(String id, SessionType type) async {
    if (!isValidUuid(id)) return null;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(type: type, updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
    return updated;
  }

  /// Persists the execution mode derived for a session that predates pinned
  /// execution modes, so later turns reuse the derived value rather than
  /// re-deriving it against a possibly changed deployment.
  Future<Session?> updateExecutionMode(String id, ExecutionMode mode) async {
    if (!isValidUuid(id)) return null;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    if (session.executionMode == mode) return session;
    final updated = session.copyWith(executionMode: mode, updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
    return updated;
  }

  /// Updates the persisted provider override for an existing session.
  Future<Session?> updateProvider(String id, String? provider) async {
    if (!isValidUuid(id)) return null;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(provider: provider, updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
    return updated;
  }

  /// Types that cannot be deleted (system-managed sessions).
  static const protectedTypes = {SessionType.main, SessionType.channel, SessionType.cron, SessionType.task};

  Future<int> deleteSession(String id) {
    if (!isValidUuid(id)) return Future.value(0);
    return _repoLock.acquire(p.join(baseDir, '.session_keys.json'), () => _deleteSessionLocked(id));
  }

  Future<int> _deleteSessionLocked(String id) async {
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) {
      await _removeMappingsForSessionIdLocked(id);
      return 0;
    }
    Session? sessionForEvent;
    try {
      final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final session = Session.fromJson(json);
      if (protectedTypes.contains(session.type)) {
        throw StateError('Cannot delete ${session.type.name} session');
      }
      sessionForEvent = session;
    } catch (e) {
      if (e is StateError) rethrow;
      // Malformed meta — allow delete
    }
    final dir = Directory(p.join(baseDir, id));
    await dir.delete(recursive: true);
    await _removeMappingsForSessionIdLocked(id);
    eventBus?.fire(
      SessionEndedEvent(
        sessionId: id,
        sessionKey: sessionForEvent?.channelKey,
        sessionType: sessionForEvent?.type.name ?? 'unknown',
        timestamp: DateTime.now(),
      ),
    );
    return 1;
  }

  Future<void> _removeMappingsForSessionIdLocked(String id) async {
    final indexFile = File(p.join(baseDir, '.session_keys.json'));
    final keyIndex = await _readKeyIndex(indexFile);
    final originalLength = keyIndex.length;
    keyIndex.removeWhere((_, sessionId) => sessionId == id);
    if (keyIndex.length != originalLength) {
      await atomicWriteJson(indexFile, keyIndex);
    }
  }

  /// Writes updated session metadata to disk.
  Future<void> _updateSession(Session session) async {
    final metaFile = File(p.join(baseDir, session.id, 'meta.json'));
    await atomicWriteJson(metaFile, session.toJson());
  }
}
