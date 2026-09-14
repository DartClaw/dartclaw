import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../api/sse_broadcast.dart';
import '../concurrency/session_mutation_coordinator.dart';
import '../task/task_service.dart';

enum InboxWorkSignal { messagePersisted, turnStarted, inputRequested }

enum InboxFilter { all, unread, waiting, running, done, failed, drafts }

final class InboxMutationException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const new(this.statusCode, this.code, this.message);
}

final class InboxMutationResult {
  final String sessionId;
  final bool accepted;
  final String code;
  final String message;
  final int revision;

  const new({
    required this.sessionId,
    required this.accepted,
    required this.code,
    required this.message,
    required this.revision,
  });

  Map<String, Object> toJson() => {
    'session_id': sessionId,
    'accepted': accepted,
    'code': code,
    'message': message,
    'conversation_revision': revision,
  };
}

final class InboxEntry {
  final Session session;
  final int revision;
  final int latestMessageCursor;
  final bool unread;
  final bool waiting;
  final bool running;
  final bool failed;
  final bool done;
  final bool localDraft;
  final String? parentSessionId;
  final DateTime? runningSince;

  const new({
    required this.session,
    required this.revision,
    required this.latestMessageCursor,
    required this.unread,
    required this.waiting,
    required this.running,
    required this.failed,
    required this.done,
    required this.localDraft,
    this.parentSessionId,
    this.runningSince,
  });
}

final class InboxPage {
  final List<InboxEntry> entries;
  final int total;
  final int filteredTotal;
  final int waitingTotal;
  final String? nextCursor;
  final String? nextAttentionSessionId;

  const new({
    required this.entries,
    required this.total,
    required this.filteredTotal,
    required this.waitingTotal,
    this.nextCursor,
    this.nextAttentionSessionId,
  });
}

final class AttentionItem {
  final String eventId;
  final String sessionId;
  final String title;
  final String detail;
  final String source;
  final DateTime occurredAt;
  final String status;
  final String? attemptId;
  final String? turnId;
  final String? requestId;
  final String? messageId;
  final String? recordId;
  final bool unread;
  final bool dismissible;
  final bool actionAvailable;
  final int revision;

  const new({
    required this.eventId,
    required this.sessionId,
    required this.title,
    required this.detail,
    required this.source,
    required this.occurredAt,
    required this.status,
    this.attemptId,
    this.turnId,
    this.requestId,
    this.messageId,
    this.recordId,
    required this.unread,
    required this.dismissible,
    required this.actionAvailable,
    required this.revision,
  });
}

final class AttentionPage {
  final List<AttentionItem> items;
  final int total;
  final int unreadTotal;
  final String? nextCursor;

  const new({required this.items, required this.total, required this.unreadTotal, this.nextCursor});
}

typedef ApprovalResolver = Future<ConversationDisplayRecord> Function({
  required String sessionId,
  required String attemptId,
  required String turnId,
  required String requestId,
  required bool approved,
  int? expectedRevision,
});

/// Coordinates durable conversation inbox and attention projections.
final class ConversationInboxService implements MessageServiceObserver {
  static const maxPageSize = 200;

  final SessionService sessions;
  final MessageService messages;
  final SessionMutationCoordinator mutations;
  final SseBroadcast? updates;
  final bool Function(String sessionId) isSessionRunning;
  final DateTime Function() clock;
  final int autoSettleIdleDays;
  ApprovalResolver? _approvalResolver;
  StreamSubscription<TaskStatusChangedEvent>? _taskEvents;

  new({
    required this.sessions,
    required this.messages,
    required this.mutations,
    this.updates,
    bool Function(String sessionId)? isSessionRunning,
    DateTime Function()? clock,
    this.autoSettleIdleDays = 0,
    ApprovalResolver? approvalResolver,
  }) : isSessionRunning = isSessionRunning ?? ((_) => false),
       clock = clock ?? DateTime.now,
       _approvalResolver = approvalResolver;

  void bindApprovalResolver(ApprovalResolver resolver) {
    if (_approvalResolver != null && !identical(_approvalResolver, resolver)) {
      throw StateError('The attention approval resolver is already bound');
    }
    _approvalResolver = resolver;
  }

  void subscribeToTaskCompletion(EventBus events, TaskService tasks) {
    if (_taskEvents != null) throw StateError('Task completion reevaluation is already subscribed');
    _taskEvents = events.on<TaskStatusChangedEvent>().listen((event) {
      if (!event.newStatus.terminal) return;
      unawaited(() async {
        final task = await tasks.get(event.taskId);
        final sessionId = task?.sessionId;
        if (sessionId != null) await reevaluateAutoSettle(sessionId);
      }());
    });
  }

  Future<void> dispose() async {
    await _taskEvents?.cancel();
    _taskEvents = null;
  }

  @override
  void onMessageAppended(Message message) {
    unawaited(handleWorkSignal(message.sessionId, InboxWorkSignal.messagePersisted));
  }

  @override
  void onMessagesCleared(String sessionId, List<String> messageIds) {}

  Future<InboxPage> inbox({
    String principal = 'owner',
    InboxFilter filter = InboxFilter.all,
    String search = '',
    Set<String> localDraftSessionIds = const {},
    String? cursor,
    int limit = 50,
    bool settled = false,
    String? currentSessionId,
  }) async {
    _requirePageSize(limit);
    final normalizedSearch = search.trim().toLowerCase();
    final entries = <InboxEntry>[];
    final visibleSessions = (await sessions.listSessions(types: SessionType.values))
        .where((session) => SessionService.isVisibleToPrincipal(session, principal))
        .where((session) => session.type != SessionType.task && session.type != SessionType.logicalAgent)
        .toList(growable: false);
    final states = <String, ConversationState>{};
    final parentSessionIds = <String, String>{};
    for (final session in visibleSessions) {
      final state = await sessions.getConversationState(session.id);
      states[session.id] = state;
      for (final branch in state.branches.where((branch) => branch.completed)) {
        parentSessionIds[branch.destinationSessionId] = branch.sourceSessionId;
      }
    }
    for (final session in visibleSessions) {
      if (session.type == SessionType.archive) {
        continue;
      }
      if ((session.settledAt != null) != settled) continue;
      if (normalizedSearch.isNotEmpty && !(session.title ?? '').toLowerCase().contains(normalizedSearch)) continue;
      entries.add(
        await _entry(
          session,
          states[session.id]!,
          localDraftSessionIds.contains(session.id),
          parentSessionIds[session.id],
        ),
      );
    }
    entries.sort(settled ? _compareSettled : _compareActive);
    final total = entries.length;
    final waitingTotal = entries.where((entry) => entry.waiting).length;
    final nextAttentionSessionId = entries.where((entry) => entry.waiting).firstOrNull?.session.id;
    final filtered = entries.where((entry) => _matches(entry, filter)).toList(growable: false);
    final filteredTotal = filtered.length;
    var start = 0;
    if (cursor != null) {
      final boundary = _decodeCursor(
        cursor,
        settled ? 'inbox-settled' : 'inbox-active',
        'INVALID_INBOX_CURSOR',
        'Inbox cursor is unavailable',
      );
      start = filtered.indexWhere((entry) => _compareInboxToCursor(entry, boundary, settled) > 0);
      if (start < 0) start = filtered.length;
    }
    final page = filtered.skip(start).take(limit).toList(growable: false);
    if (currentSessionId != null && !page.any((entry) => entry.session.id == currentSessionId)) {
      final current = filtered.where((entry) => entry.session.id == currentSessionId).firstOrNull;
      if (current != null && page.length < limit) page.add(current);
    }
    final hasMore = start + page.length < filtered.length;
    return InboxPage(
      entries: page,
      total: total,
      filteredTotal: filteredTotal,
      waitingTotal: waitingTotal,
      nextCursor: hasMore && page.isNotEmpty
          ? _encodeCursor(
              settled ? 'inbox-settled' : 'inbox-active',
              settled ? page.last.session.settledAt! : page.last.session.createdAt,
              page.last.session.id,
            )
          : null,
      nextAttentionSessionId: nextAttentionSessionId,
    );
  }

  Future<AttentionPage> attention({String principal = 'owner', String? cursor, int limit = 50}) async {
    _requirePageSize(limit);
    final sessionsById = <String, Session>{};
    final raw = <_AttentionCandidate>[];
    for (final session in await sessions.listSessions(types: SessionType.values)) {
      if (!SessionService.isVisibleToPrincipal(session, principal) ||
          session.type == SessionType.task ||
          session.type == SessionType.logicalAgent) {
        continue;
      }
      sessionsById[session.id] = session;
      final state = await sessions.getConversationState(session.id);
      final messageByAttemptId = <String, String>{};
      for (final submission in state.submissions) {
        final attemptId = submission.attemptId;
        if (attemptId != null) messageByAttemptId[attemptId] = submission.messageId;
      }
      for (final record in state.records) {
        final eventId = 'record:${record.id}';
        raw.add(
          _AttentionCandidate(
            eventId: eventId,
            sessionId: session.id,
            title: record.kind == ConversationRecordKind.approval ? record.label : 'Tool ${record.label}',
            detail: record.result ?? record.arguments ?? '',
            source: session.channelKey ?? session.type.name,
            occurredAt: record.updatedAt,
            status: record.state.name,
            attemptId: record.attemptId,
            turnId: record.turnId,
            requestId: record.kind == ConversationRecordKind.approval ? record.id : null,
            messageId: messageByAttemptId[record.attemptId],
            recordId: record.id,
            dismissible:
                record.state != ConversationRecordState.pending && record.state != ConversationRecordState.resolving,
            actionAvailable:
                session.type != SessionType.archive &&
                record.kind == ConversationRecordKind.approval &&
                record.state == ConversationRecordState.pending,
            revision: state.revision,
          ),
        );
      }
      for (final submission in state.submissions.where((item) => _isAttentionSubmission(item.workState))) {
        final eventId = 'submission:${submission.submissionId}';
        raw.add(
          _AttentionCandidate(
            eventId: eventId,
            sessionId: session.id,
            title: switch (submission.workState) {
              ConversationWorkState.completed => 'Conversation completed',
              ConversationWorkState.failed => 'Conversation failed',
              ConversationWorkState.cancelled => 'Conversation cancelled',
              _ => 'Conversation update',
            },
            detail: submission.detail ?? '',
            source: session.channelKey ?? session.type.name,
            occurredAt: submission.updatedAt,
            status: submission.workState.name,
            messageId: submission.messageId,
            dismissible: true,
            actionAvailable: false,
            revision: state.revision,
          ),
        );
      }
    }
    raw.sort((left, right) {
      final byTime = right.occurredAt.compareTo(left.occurredAt);
      return byTime != 0 ? byTime : left.eventId.compareTo(right.eventId);
    });
    final items = <AttentionItem>[];
    final readPositions = <String, int>{};
    for (final entry in sessionsById.entries) {
      final sessionItems = raw.where((candidate) => candidate.sessionId == entry.key).toList(growable: false);
      readPositions[entry.key] = sessionItems.indexWhere(
        (candidate) => candidate.eventId == entry.value.attentionReadEventId,
      );
    }
    for (final candidate in raw) {
      if (sessionsById[candidate.sessionId]!.dismissedAttentionEventIds.contains(candidate.eventId)) continue;
      final sessionItems = raw.where((item) => item.sessionId == candidate.sessionId).toList(growable: false);
      final itemIndex = sessionItems.indexOf(candidate);
      final readIndex = readPositions[candidate.sessionId] ?? -1;
      items.add(candidate.toItem(unread: readIndex < 0 || itemIndex < readIndex));
    }
    final unreadTotal = items.where((item) => item.unread).length;
    var start = 0;
    if (cursor != null) {
      final boundary = _decodeCursor(
        cursor,
        'attention',
        'INVALID_ATTENTION_CURSOR',
        'Attention cursor is unavailable',
      );
      start = items.indexWhere((item) => _compareAttentionToCursor(item, boundary) > 0);
      if (start < 0) start = items.length;
    }
    final page = items.skip(start).take(limit).toList(growable: false);
    return AttentionPage(
      items: page,
      total: items.length,
      unreadTotal: unreadTotal,
      nextCursor: start + page.length < items.length && page.isNotEmpty
          ? _encodeCursor('attention', page.last.occurredAt, page.last.eventId)
          : null,
    );
  }

  Future<List<InboxMutationResult>> settleMany(
    List<({String sessionId, int expectedRevision})> members, {
    Set<String> localDraftSessionIds = const {},
  }) async {
    final results = <InboxMutationResult>[];
    for (final member in members) {
      results.add(
        await _settle(member.sessionId, member.expectedRevision, localDraftSessionIds.contains(member.sessionId)),
      );
    }
    return results;
  }

  Future<InboxMutationResult> restore(String sessionId, int expectedRevision) => mutations.run(sessionId, () async {
    final current = await _snapshot(sessionId);
    if (current.state.revision != expectedRevision) {
      return _unchanged(current, 'STALE_CONVERSATION_REVISION', 'Conversation state changed');
    }
    if (current.session.settledAt == null) {
      return _unchanged(current, 'ALREADY_ACTIVE', 'Conversation is already active');
    }
    return _writeMetadata(
      current,
      expectedRevision,
      clearSettledAt: true,
      code: 'RESTORED',
      message: 'Conversation restored',
    );
  });

  Future<InboxMutationResult> advanceRead({
    required String sessionId,
    required int expectedRevision,
    required String visibleMessageId,
    required bool foreground,
    Set<String> localDraftSessionIds = const {},
  }) async {
    final result = await mutations.run(sessionId, () async {
      final current = await _snapshot(sessionId);
      if (current.state.revision != expectedRevision) {
        return _unchanged(current, 'STALE_CONVERSATION_REVISION', 'Conversation state changed');
      }
      if (!foreground) {
        return _unchanged(current, 'TAB_NOT_FOREGROUND', 'Read boundary was not visible in a foreground tab');
      }
      final message = await messages.getMessage(sessionId, visibleMessageId);
      if (message == null) return _unchanged(current, 'MESSAGE_NOT_VISIBLE', 'Read boundary is unavailable');
      if (message.cursor <= current.session.readMessageCursor) {
        return _unchanged(current, 'ALREADY_READ', 'Read boundary is already recorded');
      }
      return _writeMetadata(
        current,
        expectedRevision,
        readMessageCursor: message.cursor,
        code: 'READ_ADVANCED',
        message: 'Read boundary advanced',
      );
    });
    if (result.accepted) {
      await reevaluateAutoSettle(sessionId, localDraftSessionIds: localDraftSessionIds);
    }
    return result;
  }

  Future<InboxMutationResult> markAttentionRead({
    required String sessionId,
    required int expectedRevision,
    required String eventId,
  }) => mutations.run(sessionId, () async {
    final current = await _snapshot(sessionId);
    if (current.state.revision != expectedRevision) {
      return _unchanged(current, 'STALE_CONVERSATION_REVISION', 'Conversation state changed');
    }
    if (!_attentionEventExists(current.state, eventId)) {
      return _unchanged(current, 'ATTENTION_EVENT_NOT_FOUND', 'Attention event is unavailable');
    }
    return _writeMetadata(
      current,
      expectedRevision,
      attentionReadEventId: eventId,
      code: 'ATTENTION_READ',
      message: 'Attention feed marked read',
    );
  });

  Future<InboxMutationResult> dismissAttention({
    required String sessionId,
    required int expectedRevision,
    required String eventId,
  }) => mutations.run(sessionId, () async {
    final current = await _snapshot(sessionId);
    if (current.state.revision != expectedRevision) {
      return _unchanged(current, 'STALE_CONVERSATION_REVISION', 'Conversation state changed');
    }
    if (!_attentionEventExists(current.state, eventId)) {
      return _unchanged(current, 'ATTENTION_EVENT_NOT_FOUND', 'Attention event is unavailable');
    }
    if (_attentionEventPending(current.state, eventId)) {
      return _unchanged(current, 'ATTENTION_PENDING', 'Pending requests cannot be dismissed');
    }
    final next = [...current.session.dismissedAttentionEventIds.where((id) => id != eventId), eventId];
    return _writeMetadata(
      current,
      expectedRevision,
      dismissedAttentionEventIds: next,
      code: 'ATTENTION_DISMISSED',
      message: 'Attention item dismissed',
    );
  });

  Future<ConversationDisplayRecord> resolveAttention({
    required String principal,
    required String eventId,
    required String sessionId,
    required String attemptId,
    required String turnId,
    required String requestId,
    required int expectedRevision,
    required bool approved,
  }) async {
    final session = await sessions.getSession(sessionId);
    if (session == null || !SessionService.isVisibleToPrincipal(session, principal)) {
      throw const InboxMutationException(404, 'ATTENTION_EVENT_NOT_FOUND', 'Attention event is unavailable');
    }
    if (session.type == SessionType.archive || eventId != 'record:$requestId') {
      throw const InboxMutationException(409, 'ATTENTION_ACTION_UNAVAILABLE', 'Attention action is unavailable');
    }
    final state = await sessions.getConversationState(sessionId);
    if (state.revision != expectedRevision) {
      throw const InboxMutationException(409, 'STALE_CONVERSATION_REVISION', 'Conversation state changed');
    }
    final record = state.findRecord(requestId);
    if (record == null ||
        record.kind != ConversationRecordKind.approval ||
        record.attemptId != attemptId ||
        record.turnId != turnId ||
        (record.expiresAt != null && !record.expiresAt!.isAfter(clock().toUtc())) ||
        record.state != ConversationRecordState.pending) {
      throw const InboxMutationException(409, 'ATTENTION_ACTION_UNAVAILABLE', 'Attention action is unavailable');
    }
    final resolver = _approvalResolver;
    if (resolver == null) {
      throw const InboxMutationException(409, 'ATTENTION_ACTION_UNAVAILABLE', 'Attention action is unavailable');
    }
    return resolver(
      sessionId: sessionId,
      attemptId: attemptId,
      turnId: turnId,
      requestId: requestId,
      approved: approved,
      expectedRevision: expectedRevision,
    );
  }

  Future<void> handleWorkSignal(String sessionId, InboxWorkSignal signal) => mutations.run(sessionId, () async {
    final current = await _snapshotOrNull(sessionId);
    if (current == null || current.session.settledAt == null || current.session.type == SessionType.archive) return;
    await _writeMetadata(
      current,
      current.state.revision,
      clearSettledAt: true,
      code: 'AUTO_RESTORED',
      message: 'New work restored the conversation',
    );
  });

  Future<int> autoSettleIdleSessions({Set<String> localDraftSessionIds = const {}}) async {
    if (autoSettleIdleDays <= 0) return 0;
    var settled = 0;
    for (final session in await sessions.listSessions(types: SessionType.values)) {
      final result = await reevaluateAutoSettle(session.id, localDraftSessionIds: localDraftSessionIds);
      if (result?.accepted == true) settled++;
    }
    return settled;
  }

  Future<InboxMutationResult?> reevaluateAutoSettle(String sessionId, {Set<String> localDraftSessionIds = const {}}) {
    if (autoSettleIdleDays <= 0) return Future.value();
    return mutations.run(sessionId, () async {
      final current = await _snapshotOrNull(sessionId);
      if (current == null || current.session.settledAt != null || current.session.type == SessionType.archive) {
        return null;
      }
      final latest = (await messages.getMessages(sessionId)).lastOrNull;
      final idleSince = latest?.createdAt ?? current.session.updatedAt;
      if (idleSince.add(Duration(days: autoSettleIdleDays)).isAfter(clock().toUtc())) return null;
      final eligible = await _eligible(current, localDraftSessionIds.contains(sessionId));
      if (!eligible.ok) return null;
      return _writeMetadata(
        current,
        current.state.revision,
        settledAt: clock().toUtc(),
        code: 'AUTO_SETTLED',
        message: 'Conversation settled after inactivity',
      );
    });
  }

  Future<InboxMutationResult> _settle(String sessionId, int expectedRevision, bool localDraft) =>
      mutations.run(sessionId, () async {
        final current = await _snapshot(sessionId);
        if (current.state.revision != expectedRevision) {
          return _unchanged(current, 'STALE_CONVERSATION_REVISION', 'Conversation state changed');
        }
        if (current.session.settledAt != null) {
          return _unchanged(current, 'ALREADY_SETTLED', 'Conversation is already settled');
        }
        final eligible = await _eligible(current, localDraft);
        if (!eligible.ok) return _unchanged(current, eligible.code, eligible.message);
        return _writeMetadata(
          current,
          expectedRevision,
          settledAt: clock().toUtc(),
          code: 'SETTLED',
          message: 'Conversation settled',
        );
      });

  Future<({bool ok, String code, String message})> _eligible(
    ({Session session, ConversationState state}) current,
    bool localDraft,
  ) async {
    if (current.session.type != SessionType.user && current.session.type != SessionType.main) {
      return (ok: false, code: 'INELIGIBLE_SESSION', message: 'Only ordinary conversations can settle');
    }
    if (localDraft) return (ok: false, code: 'LOCAL_DRAFT', message: 'This device has a local draft');
    if (isSessionRunning(current.session.id) || current.state.submissions.any((item) => _isActive(item.workState))) {
      return (ok: false, code: 'WORK_RUNNING', message: 'Conversation still has running work');
    }
    if (current.state.records.any(
      (record) => record.kind == ConversationRecordKind.approval && record.state == ConversationRecordState.pending,
    )) {
      return (ok: false, code: 'WAITING_FOR_INPUT', message: 'Conversation is waiting for input');
    }
    final latestSubmission = [...current.state.submissions]
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    if (latestSubmission.isEmpty || latestSubmission.first.workState != ConversationWorkState.completed) {
      return (ok: false, code: 'WORK_NOT_COMPLETED', message: 'Conversation has not completed successfully');
    }
    final stored = await messages.getMessages(current.session.id);
    final latestCursor = stored.lastOrNull?.cursor ?? 0;
    if (current.session.readMessageCursor < latestCursor) {
      return (ok: false, code: 'UNREAD_MESSAGES', message: 'Conversation has unread messages');
    }
    if (_hasUnreadAttention(current.session, current.state)) {
      return (ok: false, code: 'UNREAD_ATTENTION', message: 'Conversation still needs attention');
    }
    return (ok: true, code: 'ELIGIBLE', message: 'Conversation is eligible to settle');
  }

  Future<InboxEntry> _entry(Session session, ConversationState state, bool localDraft, String? parentSessionId) async {
    final stored = await messages.getMessages(session.id);
    final latestCursor = stored.lastOrNull?.cursor ?? 0;
    final running = isSessionRunning(session.id) || state.submissions.any((item) => _isActive(item.workState));
    final waiting = state.records.any(
      (record) => record.kind == ConversationRecordKind.approval && record.state == ConversationRecordState.pending,
    );
    final latest = [...state.submissions]..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    final latestState = latest.firstOrNull?.workState;
    return InboxEntry(
      session: session,
      revision: state.revision,
      latestMessageCursor: latestCursor,
      unread: session.readMessageCursor < latestCursor,
      waiting: waiting,
      running: running,
      failed: latestState == ConversationWorkState.failed,
      done: latestState == ConversationWorkState.completed,
      localDraft: localDraft,
      parentSessionId: parentSessionId,
      runningSince: latest.where((item) => _isActive(item.workState)).firstOrNull?.updatedAt,
    );
  }

  Future<({Session session, ConversationState state})> _snapshot(String sessionId) async {
    final result = await _snapshotOrNull(sessionId);
    if (result == null) throw const InboxMutationException(404, 'SESSION_NOT_FOUND', 'Session not found');
    return result;
  }

  Future<({Session session, ConversationState state})?> _snapshotOrNull(String sessionId) async {
    final session = await sessions.getSession(sessionId);
    if (session == null) return null;
    try {
      return (session: session, state: await sessions.getConversationState(sessionId));
    } on StateError {
      return null;
    }
  }

  Future<InboxMutationResult> _writeMetadata(
    ({Session session, ConversationState state}) current,
    int expectedRevision, {
    DateTime? settledAt,
    bool clearSettledAt = false,
    int? readMessageCursor,
    String? attentionReadEventId,
    List<String>? dismissedAttentionEventIds,
    required String code,
    required String message,
  }) async {
    try {
      final updated = await sessions.updateInboxMetadata(
        id: current.session.id,
        expectedConversationRevision: expectedRevision,
        settledAt: settledAt,
        clearSettledAt: clearSettledAt,
        readMessageCursor: readMessageCursor,
        attentionReadEventId: attentionReadEventId,
        dismissedAttentionEventIds: dismissedAttentionEventIds,
      );
      updates?.broadcast('conversation_changed', {
        'session_id': current.session.id,
        'revision': updated.state.revision,
      });
      return InboxMutationResult(
        sessionId: current.session.id,
        accepted: true,
        code: code,
        message: message,
        revision: updated.state.revision,
      );
    } on ConversationRevisionMismatch catch (error) {
      return InboxMutationResult(
        sessionId: current.session.id,
        accepted: false,
        code: 'STALE_CONVERSATION_REVISION',
        message: 'Conversation state changed',
        revision: error.actual,
      );
    }
  }

  InboxMutationResult _unchanged(({Session session, ConversationState state}) current, String code, String message) =>
      InboxMutationResult(
        sessionId: current.session.id,
        accepted: false,
        code: code,
        message: message,
        revision: current.state.revision,
      );

  void _requirePageSize(int limit) {
    if (limit < 1 || limit > maxPageSize) {
      throw const InboxMutationException(400, 'INVALID_PAGE_SIZE', 'Page size must be between 1 and 200');
    }
  }

  bool _matches(InboxEntry entry, InboxFilter filter) => switch (filter) {
    InboxFilter.all => true,
    InboxFilter.unread => entry.unread,
    InboxFilter.waiting => entry.waiting,
    InboxFilter.running => entry.running,
    InboxFilter.done => entry.done,
    InboxFilter.failed => entry.failed,
    InboxFilter.drafts => entry.localDraft,
  };

  bool _attentionEventExists(ConversationState state, String eventId) {
    if (eventId.startsWith('record:')) return state.findRecord(eventId.substring(7)) != null;
    if (eventId.startsWith('submission:')) return state.findSubmission(eventId.substring(11)) != null;
    return false;
  }

  bool _attentionEventPending(ConversationState state, String eventId) {
    if (!eventId.startsWith('record:')) return false;
    final record = state.findRecord(eventId.substring(7));
    return record?.state == ConversationRecordState.pending || record?.state == ConversationRecordState.resolving;
  }

  bool _hasUnreadAttention(Session session, ConversationState state) {
    final candidates =
        <({String id, DateTime at})>[
          for (final record in state.records) (id: 'record:${record.id}', at: record.updatedAt),
          for (final submission in state.submissions.where((item) => _isAttentionSubmission(item.workState)))
            (id: 'submission:${submission.submissionId}', at: submission.updatedAt),
        ]..sort((left, right) {
          final byTime = right.at.compareTo(left.at);
          return byTime != 0 ? byTime : left.id.compareTo(right.id);
        });
    final markerIndex = candidates.indexWhere((candidate) => candidate.id == session.attentionReadEventId);
    for (var index = 0; index < candidates.length; index += 1) {
      if (session.dismissedAttentionEventIds.contains(candidates[index].id)) continue;
      if (markerIndex < 0 || index < markerIndex) return true;
    }
    return false;
  }
}

final class _AttentionCandidate {
  final String eventId;
  final String sessionId;
  final String title;
  final String detail;
  final String source;
  final DateTime occurredAt;
  final String status;
  final String? attemptId;
  final String? turnId;
  final String? requestId;
  final String? messageId;
  final String? recordId;
  final bool dismissible;
  final bool actionAvailable;
  final int revision;

  const new({
    required this.eventId,
    required this.sessionId,
    required this.title,
    required this.detail,
    required this.source,
    required this.occurredAt,
    required this.status,
    this.attemptId,
    this.turnId,
    this.requestId,
    this.messageId,
    this.recordId,
    required this.dismissible,
    required this.actionAvailable,
    required this.revision,
  });

  AttentionItem toItem({required bool unread}) => AttentionItem(
    eventId: eventId,
    sessionId: sessionId,
    title: title,
    detail: detail,
    source: source,
    occurredAt: occurredAt,
    status: status,
    attemptId: attemptId,
    turnId: turnId,
    requestId: requestId,
    messageId: messageId,
    recordId: recordId,
    unread: unread,
    dismissible: dismissible,
    actionAvailable: actionAvailable,
    revision: revision,
  );
}

bool _isActive(ConversationWorkState state) =>
    state == ConversationWorkState.accepted ||
    state == ConversationWorkState.queued ||
    state == ConversationWorkState.held ||
    state == ConversationWorkState.dispatching ||
    state == ConversationWorkState.running ||
    state == ConversationWorkState.stopping ||
    state == ConversationWorkState.uncertain;

bool _isAttentionSubmission(ConversationWorkState state) =>
    state == ConversationWorkState.completed ||
    state == ConversationWorkState.failed ||
    state == ConversationWorkState.cancelled;

int _compareActive(InboxEntry left, InboxEntry right) {
  final byCreatedAt = right.session.createdAt.compareTo(left.session.createdAt);
  return byCreatedAt != 0 ? byCreatedAt : left.session.id.compareTo(right.session.id);
}

int _compareSettled(InboxEntry left, InboxEntry right) {
  final bySettledAt = right.session.settledAt!.compareTo(left.session.settledAt!);
  return bySettledAt != 0 ? bySettledAt : left.session.id.compareTo(right.session.id);
}

typedef _PageBoundary = ({DateTime timestamp, String id});

String _encodeCursor(String kind, DateTime timestamp, String id) {
  final bytes = utf8.encode(jsonEncode({'v': 1, 'k': kind, 't': timestamp.toUtc().toIso8601String(), 'i': id}));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

_PageBoundary _decodeCursor(String cursor, String kind, String code, String message) {
  try {
    final padded = cursor.padRight(cursor.length + (4 - cursor.length % 4) % 4, '=');
    final value = jsonDecode(utf8.decode(base64Url.decode(padded)));
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['v'] != 1 ||
        value['k'] != kind ||
        value['t'] is! String ||
        value['i'] is! String ||
        (value['i'] as String).isEmpty) {
      throw const FormatException();
    }
    final timestamp = DateTime.tryParse(value['t'] as String);
    if (timestamp == null || !timestamp.isUtc) throw const FormatException();
    return (timestamp: timestamp, id: value['i'] as String);
  } on Object {
    throw InboxMutationException(400, code, message);
  }
}

int _compareInboxToCursor(InboxEntry entry, _PageBoundary boundary, bool settled) {
  final timestamp = settled ? entry.session.settledAt! : entry.session.createdAt;
  final byTime = boundary.timestamp.compareTo(timestamp);
  return byTime != 0 ? byTime : entry.session.id.compareTo(boundary.id);
}

int _compareAttentionToCursor(AttentionItem item, _PageBoundary boundary) {
  final byTime = boundary.timestamp.compareTo(item.occurredAt);
  return byTime != 0 ? byTime : item.eventId.compareTo(boundary.id);
}
