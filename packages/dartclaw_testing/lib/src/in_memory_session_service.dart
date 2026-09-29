import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

/// In-memory [SessionService] for package tests that do not need filesystem IO.
class InMemorySessionService implements SessionService {
  /// Session types that mirror the real service's delete protections.
  static const protectedTypes = {SessionType.main, SessionType.channel, SessionType.cron, SessionType.task};

  /// Creates an in-memory session service.
  new({this.baseDir = ':memory:', this.eventBus, String Function()? idGenerator, SessionServiceObserver? observer})
    : _idGenerator = idGenerator,
      _observer = observer;

  @override
  final String baseDir;

  @override
  final EventBus? eventBus;

  @override
  int get maxProcessSessions => 32;

  final String Function()? _idGenerator;
  SessionServiceObserver? _observer;
  final Map<String, Session> _sessionsById = <String, Session>{};
  final Map<String, String> _sessionKeys = <String, String>{};
  final Map<String, ConversationState> _conversationStates = <String, ConversationState>{};
  final Map<String, String> _temporaryEndStates = <String, String>{};
  int _nextSessionNumber = 1;

  @override
  void registerObserver(SessionServiceObserver observer) {
    if (_observer != null) throw StateError('A session service observer is already registered');
    _observer = observer;
  }

  @override
  Future<Session> createSession({
    SessionType type = SessionType.user,
    ConversationRetention retention = ConversationRetention.durable,
    String? channelKey,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
    AgentWorkspace? workspace,
  }) => createSessionWithIdentity(
    id: _createId(),
    type: type,
    retention: retention,
    channelKey: channelKey,
    provider: provider,
    securityProfile: securityProfile,
    executionMode: executionMode,
    workspace: workspace,
  );

  @override
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
    final existing = _sessionsById[id];
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
    _sessionsById[session.id] = session;
    if (retention == ConversationRetention.process) _temporaryEndStates[session.id] = 'active';
    eventBus?.fire(
      SessionCreatedEvent(sessionId: session.id, sessionKey: channelKey, sessionType: type.name, timestamp: now),
    );
    return session;
  }

  @override
  Future<ConversationRetention?> retentionFor(String id) async => _sessionsById[id]?.retention;

  @override
  String? temporaryEndState(String id) => _temporaryEndStates[id];

  @override
  void markTemporaryEnding(String id) => _temporaryEndStates[id] = 'ending';

  @override
  void markTemporaryEndFailed(String id) => _temporaryEndStates[id] = 'end_failed';

  @override
  Future<Session> getOrCreateMainSession() {
    return getOrCreateByKey('main', type: SessionType.main);
  }

  @override
  Future<Session?> getSession(String id) async => _sessionsById[id];

  @override
  Future<ConversationState> getConversationState(String id) async {
    if (!_sessionsById.containsKey(id)) throw StateError('Session not found: $id');
    return _conversationStates[id] ?? ConversationState();
  }

  @override
  Future<void> updateConversationState(String id, ConversationState state) async {
    final session = _sessionsById[id];
    if (session == null) throw StateError('Session not found: $id');
    _conversationStates[id] = state;
    _sessionsById[id] = session.copyWith(updatedAt: DateTime.now());
  }

  @override
  Future<({Session session, ConversationState state})> updateInboxMetadata({
    required String id,
    required int expectedConversationRevision,
    DateTime? settledAt,
    bool clearSettledAt = false,
    int? readMessageCursor,
    String? attentionReadEventId,
    List<String>? dismissedAttentionEventIds,
  }) async {
    final session = _sessionsById[id];
    if (session == null) throw StateError('Session not found: $id');
    final state = _conversationStates[id] ?? ConversationState();
    if (state.revision != expectedConversationRevision) {
      throw ConversationRevisionMismatch(expectedConversationRevision, state.revision);
    }
    final bounded = dismissedAttentionEventIds == null
        ? null
        : dismissedAttentionEventIds.length <= SessionService.maxDismissedAttentionEventIds
        ? List<String>.of(dismissedAttentionEventIds, growable: false)
        : dismissedAttentionEventIds.sublist(
            dismissedAttentionEventIds.length - SessionService.maxDismissedAttentionEventIds,
          );
    final nextState = state.bumpRevision();
    final nextSession = session.copyWith(
      settledAt: clearSettledAt ? null : settledAt ?? session.settledAt,
      readMessageCursor: readMessageCursor == null || readMessageCursor >= session.readMessageCursor
          ? readMessageCursor
          : session.readMessageCursor,
      attentionReadEventId: attentionReadEventId ?? session.attentionReadEventId,
      dismissedAttentionEventIds: bounded,
      updatedAt: DateTime.now(),
    );
    _sessionsById[id] = nextSession;
    _conversationStates[id] = nextState;
    return (session: nextSession, state: nextState);
  }

  @override
  Future<List<Session>> listSessions({
    SessionType? type,
    List<SessionType>? types,
    bool includeTaskSessions = false,
  }) async {
    final taskRequested = type == SessionType.task || (types?.contains(SessionType.task) ?? false);
    final logicalAgentRequested =
        type == SessionType.logicalAgent || (types?.contains(SessionType.logicalAgent) ?? false);
    final sessions = _sessionsById.values.where((session) {
      if (session.type == SessionType.task && !includeTaskSessions && !taskRequested) {
        return false;
      }
      if (session.type == SessionType.logicalAgent && !logicalAgentRequested) {
        return false;
      }
      if (type != null && session.type != type) {
        return false;
      }
      if (types != null && !types.contains(session.type)) {
        return false;
      }
      return true;
    }).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  @override
  Future<int> updateTitle(String id, String title) async {
    return updateTitleWithProvenance(id, title, provenance: SessionTitleProvenance.system);
  }

  @override
  Future<int> updateTitleWithProvenance(String id, String title, {required SessionTitleProvenance provenance}) async {
    final session = _sessionsById[id];
    if (session == null) {
      return 0;
    }
    _sessionsById[id] = session.copyWith(
      title: title,
      titleRevision: session.titleRevision + 1,
      titleProvenance: provenance,
      updatedAt: DateTime.now(),
    );
    return 1;
  }

  @override
  Future<Session?> setAutomaticTitleFallback(String id, String title) async {
    final session = _sessionsById[id];
    if (session == null) return null;
    if (session.title?.trim().isNotEmpty ?? false) return session;
    final updated = session.copyWith(
      title: title,
      titleRevision: session.titleRevision + 1,
      titleProvenance: SessionTitleProvenance.automaticFallback,
      updatedAt: DateTime.now(),
    );
    _sessionsById[id] = updated;
    return updated;
  }

  @override
  Future<Session?> claimAutomaticTitle(String id) async {
    final session = _sessionsById[id];
    if (session == null ||
        session.automaticTitleAttempted ||
        session.titleProvenance != SessionTitleProvenance.automaticFallback) {
      return null;
    }
    final updated = session.copyWith(automaticTitleAttempted: true, updatedAt: DateTime.now());
    _sessionsById[id] = updated;
    return updated;
  }

  @override
  Future<bool> applyAutomaticTitle(String id, String title, {required int expectedRevision}) async {
    final session = _sessionsById[id];
    if (session == null ||
        session.titleRevision != expectedRevision ||
        session.titleProvenance != SessionTitleProvenance.automaticFallback ||
        !session.automaticTitleAttempted) {
      return false;
    }
    _sessionsById[id] = session.copyWith(
      title: title,
      titleRevision: session.titleRevision + 1,
      titleProvenance: SessionTitleProvenance.automaticGenerated,
      updatedAt: DateTime.now(),
    );
    return true;
  }

  @override
  Future<void> touchUpdatedAt(String id) async {
    final session = _sessionsById[id];
    if (session == null) {
      return;
    }
    _sessionsById[id] = session.copyWith(updatedAt: DateTime.now());
  }

  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
    AgentWorkspace? workspace,
  }) async {
    final existingId = _sessionKeys[key];
    if (existingId != null) {
      final session = _sessionsById[existingId];
      if (session != null && session.type != SessionType.archive) {
        final bindingAgentId = workspace?.agentId ?? session.workspace?.agentId ?? 'unconfigured';
        AgentWorkspace.requireCurrent(
          sessionId: session.id,
          agentId: bindingAgentId,
          pinned: session.workspace,
          configured: workspace,
        );
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
            updatedAt: DateTime.now(),
          );
          _sessionsById[existingId] = migrated;
          return migrated;
        }
        return session;
      }
      _sessionKeys.remove(key);
    }

    final session = await createSession(
      type: type,
      channelKey: key,
      provider: provider,
      securityProfile: securityProfile,
      executionMode: executionMode,
      workspace: workspace,
    );
    _sessionKeys[key] = session.id;
    return session;
  }

  @override
  Future<Session?> getByKey(String key) async {
    final id = _sessionKeys[key];
    if (id == null) return null;
    final session = _sessionsById[id];
    return session == null || session.type == SessionType.archive || session.channelKey != key ? null : session;
  }

  @override
  Future<void> removeKeyMapping(String key) async {
    _sessionKeys.remove(key);
  }

  @override
  Future<Session?> updateSessionType(String id, SessionType type) async {
    final session = _sessionsById[id];
    if (session == null) {
      return null;
    }
    final updated = session.copyWith(type: type, updatedAt: DateTime.now());
    _sessionsById[id] = updated;
    _notify(() => _observer?.onSessionTypeChanged(id, session.type, type));
    return updated;
  }

  @override
  Future<Session?> updateExecutionMode(String id, ExecutionMode mode) async {
    final session = _sessionsById[id];
    if (session == null) {
      return null;
    }
    if (session.executionMode == mode) return session;
    final updated = session.copyWith(executionMode: mode, updatedAt: DateTime.now());
    _sessionsById[id] = updated;
    return updated;
  }

  @override
  Future<Session?> updateProvider(String id, String? provider) async {
    final session = _sessionsById[id];
    if (session == null) {
      return null;
    }
    final updated = session.copyWith(provider: provider, updatedAt: DateTime.now());
    _sessionsById[id] = updated;
    return updated;
  }

  @override
  Future<int> deleteSession(String id) async {
    final session = _sessionsById[id];
    if (session == null) {
      return 0;
    }
    if (protectedTypes.contains(session.type)) {
      throw StateError('Cannot delete ${session.type.name} session');
    }

    _notify(() => _observer?.onSessionDeleting(id, session));
    _sessionsById.remove(id);
    _conversationStates.remove(id);
    _temporaryEndStates.remove(id);
    _sessionKeys.removeWhere((_, sessionId) => sessionId == id);
    eventBus?.fire(
      SessionEndedEvent(
        sessionId: id,
        sessionKey: session.channelKey,
        sessionType: session.type.name,
        timestamp: DateTime.now(),
      ),
    );
    return 1;
  }

  void _notify(void Function() notification) {
    try {
      notification();
    } catch (_) {}
  }

  String _createId() {
    final generator = _idGenerator;
    if (generator != null) {
      return generator();
    }
    return 'session-${_nextSessionNumber++}';
  }
}
