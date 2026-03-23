import 'package:dartclaw_core/dartclaw_core.dart';

/// In-memory [SessionService] for package tests that do not need filesystem IO.
class InMemorySessionService implements SessionService {
  /// Session types that mirror the real service's delete protections.
  static const protectedTypes = {SessionType.main, SessionType.channel, SessionType.cron, SessionType.task};

  /// Creates an in-memory session service.
  InMemorySessionService({this.baseDir = ':memory:', this.eventBus, String Function()? idGenerator})
    : _idGenerator = idGenerator;

  @override
  final String baseDir;

  @override
  final EventBus? eventBus;

  final String Function()? _idGenerator;
  final Map<String, Session> _sessionsById = <String, Session>{};
  final Map<String, String> _sessionKeys = <String, String>{};
  int _nextSessionNumber = 1;

  @override
  Future<Session> createSession({SessionType type = SessionType.user, String? channelKey, String? provider}) async {
    final now = DateTime.now();
    final session = Session(
      id: _createId(),
      type: type,
      channelKey: channelKey,
      provider: provider,
      createdAt: now,
      updatedAt: now,
    );
    _sessionsById[session.id] = session;
    if (channelKey != null) {
      _sessionKeys[channelKey] = session.id;
    }
    eventBus?.fire(
      SessionCreatedEvent(sessionId: session.id, sessionKey: channelKey, sessionType: type.name, timestamp: now),
    );
    return session;
  }

  @override
  Future<Session> getOrCreateMain() {
    return getOrCreateByKey('main', type: SessionType.main);
  }

  @override
  Future<Session?> getSession(String id) async => _sessionsById[id];

  @override
  Future<List<Session>> listSessions({
    SessionType? type,
    List<SessionType>? types,
    bool includeTaskSessions = false,
  }) async {
    final taskRequested = type == SessionType.task || (types?.contains(SessionType.task) ?? false);
    final sessions = _sessionsById.values.where((session) {
      if (session.type == SessionType.task && !includeTaskSessions && !taskRequested) {
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
    final session = _sessionsById[id];
    if (session == null) {
      return 0;
    }
    _sessionsById[id] = session.copyWith(title: title, updatedAt: DateTime.now());
    return 1;
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
  Future<Session> getOrCreateByKey(String key, {SessionType type = SessionType.user, String? provider}) async {
    final existingId = _sessionKeys[key];
    if (existingId != null) {
      final session = _sessionsById[existingId];
      if (session != null && session.type != SessionType.archive) {
        if (session.type != type || session.channelKey != key || session.provider != provider) {
          final migrated = session.copyWith(type: type, channelKey: key, provider: provider, updatedAt: DateTime.now());
          _sessionsById[existingId] = migrated;
          return migrated;
        }
        return session;
      }
      _sessionKeys.remove(key);
    }

    return createSession(type: type, channelKey: key, provider: provider);
  }

  @override
  Future<Session?> updateSessionType(String id, SessionType type) async {
    final session = _sessionsById[id];
    if (session == null) {
      return null;
    }
    final updated = session.copyWith(type: type, updatedAt: DateTime.now());
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

    _sessionsById.remove(id);
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

  String _createId() {
    final generator = _idGenerator;
    if (generator != null) {
      return generator();
    }
    return 'session-${_nextSessionNumber++}';
  }
}
