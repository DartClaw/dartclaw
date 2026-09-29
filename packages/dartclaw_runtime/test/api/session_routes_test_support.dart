import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

final class PausingTailMessageService extends MessageService {
  new({required super.baseDir});

  final firstTailReadStarted = Completer<void>();
  final resumeFirstTailRead = Completer<void>();
  var _tailReadCount = 0;

  @override
  Future<List<Message>> getMessagesTail(String sessionId, {int count = 200}) async {
    _tailReadCount += 1;
    if (_tailReadCount == 1) {
      firstTailReadStarted.complete();
      await resumeFirstTailRead.future;
    }
    return super.getMessagesTail(sessionId, count: count);
  }
}

final class PausingInsertMessageService extends MessageService {
  new({required super.baseDir});

  final insertStarted = Completer<void>();
  final resumeInsert = Completer<void>();

  @override
  Future<Message> insertMessageWithIdentity({
    required String sessionId,
    required String messageId,
    required String role,
    required String content,
    String? metadata,
    required DateTime createdAt,
    bool notifyObserver = true,
  }) async {
    insertStarted.complete();
    await resumeInsert.future;
    return super.insertMessageWithIdentity(
      sessionId: sessionId,
      messageId: messageId,
      role: role,
      content: content,
      metadata: metadata,
      createdAt: createdAt,
      notifyObserver: notifyObserver,
    );
  }
}

final class PausingUpdateTitleSessionService extends SessionService {
  new({required super.baseDir});

  final updateStarted = Completer<void>();
  final resumeUpdate = Completer<void>();
  final openListStarted = Completer<void>();
  Session? _initialSession;

  @override
  Future<Session> createSession({
    SessionType type = SessionType.user,
    ConversationRetention retention = ConversationRetention.durable,
    String? channelKey,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
    AgentWorkspace? workspace,
  }) async {
    final created = await super.createSession(
      type: type,
      retention: retention,
      channelKey: channelKey,
      provider: provider,
      securityProfile: securityProfile,
      executionMode: executionMode,
      workspace: workspace,
    );
    _initialSession ??= created;
    return created;
  }

  @override
  Future<List<Session>> listSessions({
    SessionType? type,
    List<SessionType>? types,
    bool includeTaskSessions = false,
  }) async {
    final initial = _initialSession;
    if (initial != null && updateStarted.isCompleted && (type == null || type == initial.type)) {
      if (!openListStarted.isCompleted) {
        openListStarted.complete();
        return [initial];
      }
    }
    return super.listSessions(type: type, types: types, includeTaskSessions: includeTaskSessions);
  }

  @override
  Future<int> updateTitleWithProvenance(String id, String title, {required SessionTitleProvenance provenance}) async {
    updateStarted.complete();
    await resumeUpdate.future;
    return super.updateTitleWithProvenance(id, title, provenance: provenance);
  }
}

final class PausingUpdateSessionTypeSessionService extends SessionService {
  new({required super.baseDir});

  final updateStarted = Completer<void>();
  final resumeUpdate = Completer<void>();
  final openListCompleted = Completer<void>();

  @override
  Future<List<Session>> listSessions({
    SessionType? type,
    List<SessionType>? types,
    bool includeTaskSessions = false,
  }) async {
    final result = await super.listSessions(type: type, types: types, includeTaskSessions: includeTaskSessions);
    if (updateStarted.isCompleted && type == SessionType.user && !openListCompleted.isCompleted) {
      openListCompleted.complete();
    }
    return result;
  }

  @override
  Future<Session?> updateSessionType(String id, SessionType type) async {
    updateStarted.complete();
    await resumeUpdate.future;
    return super.updateSessionType(id, type);
  }
}

final class PausingFirstGetSessionService extends SessionService {
  new({required super.baseDir});

  final firstReadStarted = Completer<void>();
  final resumeFirstRead = Completer<void>();

  @override
  Future<Session?> getSession(String id) async {
    final session = await super.getSession(id);
    if (session != null && !firstReadStarted.isCompleted) {
      firstReadStarted.complete();
      await resumeFirstRead.future;
    }
    return session;
  }
}

final class OpenTrackingSessionService extends SessionService {
  new({required super.baseDir});

  final replacementCreateStarted = Completer<void>();
  Session? _initialSession;

  @override
  Future<Session> createSession({
    SessionType type = SessionType.user,
    ConversationRetention retention = ConversationRetention.durable,
    String? channelKey,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
    AgentWorkspace? workspace,
  }) async {
    if (_initialSession != null) replacementCreateStarted.complete();
    final created = await super.createSession(
      type: type,
      retention: retention,
      channelKey: channelKey,
      provider: provider,
      securityProfile: securityProfile,
      executionMode: executionMode,
      workspace: workspace,
    );
    _initialSession ??= created;
    return created;
  }

  @override
  Future<List<Session>> listSessions({
    SessionType? type,
    List<SessionType>? types,
    bool includeTaskSessions = false,
  }) async {
    final initial = _initialSession;
    if (initial != null && (type == null || type == initial.type)) return [initial];
    return super.listSessions(type: type, types: types, includeTaskSessions: includeTaskSessions);
  }
}
