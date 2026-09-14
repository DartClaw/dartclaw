import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../concurrency/repo_lock.dart';
import '../events/dartclaw_event.dart';
import '../events/event_bus.dart';
import 'atomic_write.dart';
import 'conversation_state.dart';
import 'uuid_validation.dart';

/// Raised when a session metadata mutation targets an older conversation revision.
final class ConversationRevisionMismatch implements Exception {
  final int expected;
  final int actual;

  const new(this.expected, this.actual);

  @override
  String toString() => 'Conversation revision changed (expected $expected, actual $actual)';
}

/// Receives synchronous notifications around authoritative session mutations.
abstract interface class SessionServiceObserver {
  /// Called after a type change has been persisted.
  void onSessionTypeChanged(String sessionId, SessionType oldType, SessionType newType);

  /// Called after delete protection passes and before the session directory is removed.
  void onSessionDeleting(String sessionId, Session? session);
}

/// Manages session CRUD operations backed by NDJSON file storage.
class SessionService {
  static const maxDismissedAttentionEventIds = 200;

  final String baseDir;
  final EventBus? eventBus;
  final RepoLock _repoLock;
  SessionServiceObserver? _observer;
  final int maxProcessSessions;
  final Map<String, Session> _processSessions = {};
  final Map<String, ConversationState> _processConversationStates = {};
  final Map<String, String> _processEndStates = {};
  static const _uuid = Uuid();
  static final _log = Logger('SessionService');

  new({
    required this.baseDir,
    this.eventBus,
    RepoLock? repoLock,
    SessionServiceObserver? observer,
    this.maxProcessSessions = 32,
  }) : _repoLock = repoLock ?? RepoLock(),
       _observer = observer;

  /// Registers the sole session mutation observer.
  void registerObserver(SessionServiceObserver observer) {
    if (_observer != null) throw StateError('A session service observer is already registered');
    _observer = observer;
  }

  Future<Session> createSession({
    SessionType type = SessionType.user,
    ConversationRetention retention = ConversationRetention.durable,
    String? channelKey,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
    AgentWorkspace? workspace,
  }) => createSessionWithIdentity(
    id: _uuid.v4(),
    type: type,
    retention: retention,
    channelKey: channelKey,
    provider: provider,
    securityProfile: securityProfile,
    executionMode: executionMode,
    workspace: workspace,
  );

  /// Creates a session with a caller-reserved stable identity, or returns the
  /// identical session when recovery repeats the same creation.
  Future<Session> createSessionWithIdentity({
    required String id,
    SessionType type = SessionType.user,
    ConversationRetention retention = ConversationRetention.durable,
    String? channelKey,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
    AgentWorkspace? workspace,
  }) async {
    if (!isValidUuid(id)) throw ArgumentError.value(id, 'id', 'must be a UUID');
    final existing = await getSession(id);
    if (existing != null) {
      if (existing.type != type ||
          existing.retention != retention ||
          existing.channelKey != channelKey ||
          existing.provider != provider ||
          existing.securityProfile != securityProfile ||
          existing.executionMode != executionMode ||
          existing.workspace != workspace) {
        throw StateError('Session identity is already in use: $id');
      }
      return existing;
    }
    final now = DateTime.now();
    final session = Session(
      id: id,
      type: type,
      retention: retention,
      channelKey: channelKey,
      provider: provider,
      securityProfile: securityProfile,
      executionMode: executionMode,
      workspace: workspace,
      createdAt: now,
      updatedAt: now,
    );
    if (retention == ConversationRetention.process) {
      if (type != SessionType.user) throw ArgumentError('Process-retained sessions must be user sessions');
      if (_processSessions.length >= maxProcessSessions) throw StateError('Temporary conversation capacity reached');
      _processSessions[id] = session;
      _processConversationStates[id] = ConversationState();
      _processEndStates[id] = 'active';
      eventBus?.fire(
        SessionCreatedEvent(sessionId: session.id, sessionKey: channelKey, sessionType: type.name, timestamp: now),
      );
      return session;
    }
    final dir = Directory(p.join(baseDir, id));
    await dir.create(recursive: true);
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
    final process = _processSessions[id];
    if (process != null) return process;
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
    final taskRequested = type == SessionType.task || (types?.contains(SessionType.task) ?? false);
    final logicalAgentRequested =
        type == SessionType.logicalAgent || (types?.contains(SessionType.logicalAgent) ?? false);
    final sessions = <Session>[];
    if (dir.existsSync()) {
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
    }
    for (final session in _processSessions.values) {
      if (session.type == SessionType.task && !includeTaskSessions && !taskRequested) continue;
      if (session.type == SessionType.logicalAgent && !logicalAgentRequested) continue;
      if (type != null && session.type != type) continue;
      if (types != null && !types.contains(session.type)) continue;
      sessions.add(session);
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<int> updateTitle(String id, String title) =>
      updateTitleWithProvenance(id, title, provenance: SessionTitleProvenance.system);

  Future<int> updateTitleWithProvenance(String id, String title, {required SessionTitleProvenance provenance}) async {
    final updated = await _mutateSession(
      id,
      (session) => session.copyWith(
        title: title,
        titleRevision: session.titleRevision + 1,
        titleProvenance: provenance,
        updatedAt: DateTime.now(),
      ),
    );
    return updated == null ? 0 : 1;
  }

  /// Installs the immediate first-message title only while the session is unnamed.
  Future<Session?> setAutomaticTitleFallback(String id, String title) => _mutateSession(id, (session) {
    if (session.title?.trim().isNotEmpty ?? false) return session;
    return session.copyWith(
      title: title,
      titleRevision: session.titleRevision + 1,
      titleProvenance: SessionTitleProvenance.automaticFallback,
      updatedAt: DateTime.now(),
    );
  });

  /// Claims the single schema-title attempt and returns its compare-and-set revision.
  Future<Session?> claimAutomaticTitle(String id) => _mutateSession(id, (session) {
    if (session.automaticTitleAttempted || session.titleProvenance != SessionTitleProvenance.automaticFallback) {
      return null;
    }
    return session.copyWith(automaticTitleAttempted: true, updatedAt: DateTime.now());
  });

  /// Applies a generated title only while the captured fallback is still current.
  Future<bool> applyAutomaticTitle(String id, String title, {required int expectedRevision}) async {
    var applied = false;
    await _mutateSession(id, (session) {
      if (session.titleRevision != expectedRevision ||
          session.titleProvenance != SessionTitleProvenance.automaticFallback ||
          !session.automaticTitleAttempted) {
        return session;
      }
      applied = true;
      return session.copyWith(
        title: title,
        titleRevision: session.titleRevision + 1,
        titleProvenance: SessionTitleProvenance.automaticGenerated,
        updatedAt: DateTime.now(),
      );
    });
    return applied;
  }

  Future<Session?> _mutateSession(String id, Session? Function(Session session) mutate) async {
    if (!isValidUuid(id)) return null;
    final process = _processSessions[id];
    if (process != null) {
      final updated = mutate(process);
      if (updated != null) _processSessions[id] = updated;
      return updated;
    }
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;
    return _repoLock.acquire(metaFile.path, () async {
      final session = Session.fromJson(jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>);
      final updated = mutate(session);
      if (updated == null) return null;
      if (!identical(updated, session)) await _writeSessionMeta(metaFile, updated);
      return updated;
    });
  }

  Future<void> touchUpdatedAt(String id) async {
    if (!isValidUuid(id)) return;
    final process = _processSessions[id];
    if (process != null) {
      _processSessions[id] = process.copyWith(updatedAt: DateTime.now());
      return;
    }
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(updatedAt: DateTime.now());
    await _writeSessionMeta(metaFile, updated);
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
    AgentWorkspace? workspace,
  }) async {
    return _repoLock.acquire(
      p.join(baseDir, '.session_keys.json'),
      () => _getOrCreateByKeyLocked(
        key,
        type: type,
        provider: provider,
        securityProfile: securityProfile,
        executionMode: executionMode,
        workspace: workspace,
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
    AgentWorkspace? workspace,
  }) async {
    final indexFile = File(p.join(baseDir, '.session_keys.json'));

    final keyIndex = await _readKeyIndex(indexFile);

    // Check if key already maps to a session
    final existingId = keyIndex[key];
    if (existingId != null) {
      final session = await getSession(existingId);
      if (session != null && session.type != SessionType.archive) {
        final bindingAgentId = workspace?.agentId ?? session.workspace?.agentId ?? 'unconfigured';
        AgentWorkspace.requireCurrent(
          sessionId: session.id,
          agentId: bindingAgentId,
          pinned: session.workspace,
          configured: workspace,
        );
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
      workspace: workspace,
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
    final process = _processSessions[id];
    if (process != null) {
      if (type != SessionType.user) throw StateError('Temporary conversations cannot change type');
      return process;
    }
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(type: type, updatedAt: DateTime.now());
    await _writeSessionMeta(metaFile, updated);
    _notify(() => _observer?.onSessionTypeChanged(id, session.type, type));
    return updated;
  }

  /// Persists the execution mode derived for a session that predates pinned
  /// execution modes, so later turns reuse the derived value rather than
  /// re-deriving it against a possibly changed deployment.
  Future<Session?> updateExecutionMode(String id, ExecutionMode mode) async {
    if (!isValidUuid(id)) return null;
    final process = _processSessions[id];
    if (process != null) {
      final updated = process.copyWith(executionMode: mode, updatedAt: DateTime.now());
      _processSessions[id] = updated;
      return updated;
    }
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    if (session.executionMode == mode) return session;
    final updated = session.copyWith(executionMode: mode, updatedAt: DateTime.now());
    await _writeSessionMeta(metaFile, updated);
    return updated;
  }

  /// Updates the persisted provider override for an existing session.
  Future<Session?> updateProvider(String id, String? provider) async {
    if (!isValidUuid(id)) return null;
    final process = _processSessions[id];
    if (process != null) {
      final updated = process.copyWith(provider: provider, updatedAt: DateTime.now());
      _processSessions[id] = updated;
      return updated;
    }
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(provider: provider, updatedAt: DateTime.now());
    await _writeSessionMeta(metaFile, updated);
    return updated;
  }

  /// Reads the durable ordinary-conversation state stored with the session.
  Future<ConversationState> getConversationState(String id) async {
    if (!isValidUuid(id)) throw ArgumentError('Invalid session ID');
    final process = _processConversationStates[id];
    if (process != null) return process;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) throw StateError('Session does not exist: $id');
    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final value = json['conversationState'];
    if (value == null) return ConversationState();
    if (value is! Map) throw const FormatException('conversationState must be an object');
    return ConversationState.fromJson(Map<String, dynamic>.from(value));
  }

  /// Atomically replaces the session's ordinary-conversation state.
  Future<void> updateConversationState(String id, ConversationState state) async {
    if (!isValidUuid(id)) throw ArgumentError('Invalid session ID');
    if (_processSessions.containsKey(id)) {
      _processConversationStates[id] = state;
      await touchUpdatedAt(id);
      return;
    }
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) throw StateError('Session does not exist: $id');
    await _repoLock.acquire(metaFile.path, () async {
      final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      json['conversationState'] = state.toJson();
      final session = Session.fromJson(json);
      json.addAll(session.copyWith(updatedAt: DateTime.now()).toJson());
      await atomicWriteJson(metaFile, json);
    });
  }

  /// Atomically updates inbox metadata and advances the conversation revision.
  Future<({Session session, ConversationState state})> updateInboxMetadata({
    required String id,
    required int expectedConversationRevision,
    DateTime? settledAt,
    bool clearSettledAt = false,
    int? readMessageCursor,
    String? attentionReadEventId,
    List<String>? dismissedAttentionEventIds,
  }) async {
    if (!isValidUuid(id)) throw ArgumentError('Invalid session ID');
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    return _repoLock.acquire(metaFile.path, () async {
      final processSession = _processSessions[id];
      final processState = _processConversationStates[id];
      final isProcess = processSession != null;

      Map<String, dynamic>? json;
      late final Session session;
      late final ConversationState state;
      if (processSession != null) {
        if (_processEndStates[id] != 'active' || processState == null) {
          throw StateError('Session is not active: $id');
        }
        session = processSession;
        state = processState;
      } else {
        if (!metaFile.existsSync()) throw StateError('Session does not exist: $id');
        json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        session = Session.fromJson(json);
        final rawState = json['conversationState'];
        state = rawState == null
            ? ConversationState()
            : ConversationState.fromJson(Map<String, dynamic>.from(rawState as Map));
      }
      if (state.revision != expectedConversationRevision) {
        throw ConversationRevisionMismatch(expectedConversationRevision, state.revision);
      }
      final nextState = state.bumpRevision();
      final boundedDismissed = dismissedAttentionEventIds == null
          ? null
          : dismissedAttentionEventIds.length <= maxDismissedAttentionEventIds
          ? List<String>.of(dismissedAttentionEventIds, growable: false)
          : dismissedAttentionEventIds.sublist(dismissedAttentionEventIds.length - maxDismissedAttentionEventIds);
      final nextSession = session.copyWith(
        settledAt: clearSettledAt ? null : settledAt ?? session.settledAt,
        readMessageCursor: readMessageCursor == null
            ? null
            : readMessageCursor < session.readMessageCursor
            ? session.readMessageCursor
            : readMessageCursor,
        attentionReadEventId: attentionReadEventId ?? session.attentionReadEventId,
        dismissedAttentionEventIds: boundedDismissed,
        updatedAt: DateTime.now(),
      );
      if (isProcess) {
        _processSessions[id] = nextSession;
        _processConversationStates[id] = nextState;
      } else {
        final next = nextSession.toJson()..['conversationState'] = nextState.toJson();
        await atomicWriteJson(metaFile, next);
      }
      return (session: nextSession, state: nextState);
    });
  }

  /// Types that cannot be deleted (system-managed sessions).
  static const protectedTypes = {SessionType.main, SessionType.channel, SessionType.cron, SessionType.task};

  Future<int> deleteSession(String id) {
    if (!isValidUuid(id)) return Future.value(0);
    return _repoLock.acquire(p.join(baseDir, '.session_keys.json'), () => _deleteSessionLocked(id));
  }

  Future<int> _deleteSessionLocked(String id) async {
    final process = _processSessions.remove(id);
    if (process != null) {
      _processConversationStates.remove(id);
      _processEndStates.remove(id);
      _notify(() => _observer?.onSessionDeleting(id, process));
      eventBus?.fire(
        SessionEndedEvent(
          sessionId: id,
          sessionKey: process.channelKey,
          sessionType: process.type.name,
          timestamp: DateTime.now(),
        ),
      );
      return 1;
    }
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
    _notify(() => _observer?.onSessionDeleting(id, sessionForEvent));
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

  /// Resolves the authoritative persistence boundary for storage consumers.
  Future<ConversationRetention?> retentionFor(String id) async => (await getSession(id))?.retention;

  /// Current explicit-end state for a process-retained conversation.
  String? temporaryEndState(String id) => _processEndStates[id];

  void markTemporaryEnding(String id) {
    if (_processSessions.containsKey(id)) _processEndStates[id] = 'ending';
  }

  void markTemporaryEndFailed(String id) {
    if (_processSessions.containsKey(id)) _processEndStates[id] = 'end_failed';
  }

  void _notify(void Function() notification) {
    try {
      notification();
    } catch (error, stackTrace) {
      _log.warning('Session observer failed: $error', error, stackTrace);
    }
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
    await _writeSessionMeta(metaFile, session);
  }

  Future<void> _writeSessionMeta(File metaFile, Session session) async {
    await _repoLock.acquire(metaFile.path, () async {
      final existing = metaFile.existsSync()
          ? jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
      final next = session.toJson();
      if (existing['conversationState'] case final conversationState?) {
        next['conversationState'] = conversationState;
      }
      await atomicWriteJson(metaFile, next);
    });
  }
}
