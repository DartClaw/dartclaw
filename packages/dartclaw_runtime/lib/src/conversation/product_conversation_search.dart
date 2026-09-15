import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Product-visible conversation search scope.
enum ConversationSearchScope { current, global }

/// Lifecycle filter applied before product search pagination.
enum ConversationSearchLifecycle { all, active, settled, archived }

/// One authorized, revalidated product search result.
final class ProductConversationHit {
  const new({
    required this.sessionId,
    required this.messageId,
    required this.revision,
    required this.title,
    required this.origin,
    required this.projectId,
    required this.role,
    required this.createdAt,
    required this.snippet,
    required this.highlightStart,
    required this.highlightEnd,
  });

  final String sessionId;
  final String messageId;
  final int revision;
  final String title;
  final String origin;
  final String? projectId;
  final String role;
  final DateTime createdAt;
  final String snippet;
  final int highlightStart;
  final int highlightEnd;

  String get citation => 'conversation:$sessionId/message:$messageId';

  String get href {
    final session = Uri.encodeComponent(sessionId);
    final message = Uri.encodeComponent(messageId);
    return '/sessions/$session?message=$message#message-$message';
  }

  Map<String, Object?> toJson() => {
    'session_id': sessionId,
    'message_id': messageId,
    'conversation_revision': revision,
    'title': title,
    'origin': origin,
    'project_id': projectId,
    'role': role,
    'created_at': createdAt.toUtc().toIso8601String(),
    'snippet': snippet,
    'highlight_start': highlightStart,
    'highlight_end': highlightEnd,
    'citation': citation,
    'href': href,
  };
}

/// Explicit product outcome that keeps backend failure distinct from no match.
final class ProductConversationSearchOutcome {
  const new({required this.results, required this.total, this.failure});

  final List<ProductConversationHit> results;
  final int total;
  final String? failure;

  bool get succeeded => failure == null;
}

/// Applies owner visibility and session lifecycle rules around the shared index.
final class ProductConversationSearchService {
  static const maxPageSize = 100;
  static const _snippetLength = 180;

  const new({required this.search, required this.sessions, required this.messages});

  final ConversationSearchService search;
  final SessionService sessions;
  final MessageService messages;

  Future<ProductConversationSearchOutcome> find({
    required String query,
    ConversationSearchScope scope = ConversationSearchScope.global,
    ConversationSearchLifecycle lifecycle = ConversationSearchLifecycle.all,
    String? currentSessionId,
    String? projectId,
    String principal = 'owner',
    int limit = 20,
  }) async {
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and $maxPageSize');
    }
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const ProductConversationSearchOutcome(results: [], total: 0);
    if (scope == ConversationSearchScope.current && (currentSessionId == null || currentSessionId.isEmpty)) {
      throw ArgumentError('currentSessionId is required for current search');
    }

    final eligible = <String, _EligibleSession>{};
    for (final session in await sessions.listSessions(types: SessionType.values, includeTaskSessions: true)) {
      final candidate = await _eligible(
        session,
        principal: principal,
        scope: scope,
        lifecycle: lifecycle,
        currentSessionId: currentSessionId,
        projectId: projectId,
      );
      if (candidate != null) eligible[session.id] = candidate;
    }
    if (eligible.isEmpty) return const ProductConversationSearchOutcome(results: [], total: 0);

    final outcome = await search.searchAdministrative(
      normalizedQuery,
      principals: eligible.values.map((entry) => entry.principal).toSet(),
      sessionIds: eligible.keys.toSet(),
      limit: limit,
    );
    if (!outcome.succeeded) {
      return ProductConversationSearchOutcome(results: const [], total: 0, failure: outcome.failure);
    }

    final currentEligible = <String, _EligibleSession>{};
    for (final session in await sessions.listSessions(types: SessionType.values, includeTaskSessions: true)) {
      final candidate = await _eligible(
        session,
        principal: principal,
        scope: scope,
        lifecycle: lifecycle,
        currentSessionId: currentSessionId,
        projectId: projectId,
      );
      if (candidate != null) currentEligible[session.id] = candidate;
    }
    if (!_sameEligibility(eligible, currentEligible)) {
      return const ProductConversationSearchOutcome(results: [], total: 0, failure: 'SEARCH_RESULTS_CHANGED');
    }

    final revalidated = <ProductConversationHit>[];
    for (final hit in outcome.hits) {
      final current = await sessions.getSession(hit.sessionId);
      final candidate = currentEligible[hit.sessionId];
      if (current == null || candidate == null) {
        return const ProductConversationSearchOutcome(results: [], total: 0, failure: 'SEARCH_RESULTS_CHANGED');
      }
      final message = await messages.getMessage(hit.sessionId, hit.messageId);
      if (message == null ||
          !candidate.state.includesMessage(message.id) ||
          message.role != hit.role ||
          message.createdAt.toUtc() != hit.createdAt ||
          message.content != hit.text) {
        return const ProductConversationSearchOutcome(results: [], total: 0, failure: 'SEARCH_RESULTS_CHANGED');
      }
      final snippet = _snippet(message.content, normalizedQuery);
      revalidated.add(
        ProductConversationHit(
          sessionId: hit.sessionId,
          messageId: hit.messageId,
          revision: candidate.state.revision,
          title: current.title?.trim().isNotEmpty == true ? current.title!.trim() : 'Untitled conversation',
          origin: current.channelKey ?? current.type.name,
          projectId: candidate.projectId,
          role: message.role,
          createdAt: message.createdAt,
          snippet: snippet.text,
          highlightStart: snippet.start,
          highlightEnd: snippet.end,
        ),
      );
    }
    return ProductConversationSearchOutcome(results: revalidated, total: outcome.total);
  }

  bool _sameEligibility(Map<String, _EligibleSession> before, Map<String, _EligibleSession> after) {
    if (before.length != after.length) return false;
    for (final entry in before.entries) {
      final current = after[entry.key];
      if (current == null ||
          current.principal != entry.value.principal ||
          current.projectId != entry.value.projectId ||
          current.state.revision != entry.value.state.revision) {
        return false;
      }
    }
    return true;
  }

  Future<ProductConversationHit?> resolveTarget({
    required String sessionId,
    required String messageId,
    String principal = 'owner',
  }) async {
    final session = await sessions.getSession(sessionId);
    if (session == null) return null;
    final candidate = await _eligible(
      session,
      principal: principal,
      scope: ConversationSearchScope.current,
      lifecycle: ConversationSearchLifecycle.all,
      currentSessionId: sessionId,
      projectId: null,
    );
    if (candidate == null) return null;
    final message = await messages.getMessage(sessionId, messageId);
    if (message == null || !candidate.state.includesMessage(message.id)) return null;
    return ProductConversationHit(
      sessionId: session.id,
      messageId: message.id,
      revision: candidate.state.revision,
      title: session.title?.trim().isNotEmpty == true ? session.title!.trim() : 'Untitled conversation',
      origin: session.channelKey ?? session.type.name,
      projectId: candidate.projectId,
      role: message.role,
      createdAt: message.createdAt,
      snippet: message.content,
      highlightStart: 0,
      highlightEnd: 0,
    );
  }

  Future<_EligibleSession?> _eligible(
    Session session, {
    required String principal,
    required ConversationSearchScope scope,
    required ConversationSearchLifecycle lifecycle,
    required String? currentSessionId,
    required String? projectId,
  }) async {
    if (!session.retention.isDurable) return null;
    if (!SessionService.isVisibleToPrincipal(session, principal)) return null;
    if (session.type == SessionType.task ||
        session.type == SessionType.logicalAgent ||
        session.type == SessionType.cron) {
      return null;
    }
    if (scope == ConversationSearchScope.current && session.id != currentSessionId) return null;
    if (!_matchesLifecycle(session, lifecycle)) return null;
    final state = await sessions.getConversationState(session.id);
    final effectiveProject = state.currentContext?.projectId ?? state.nextContext?.projectId;
    if (projectId != null && effectiveProject != projectId) return null;
    return _EligibleSession(
      principal: SessionService.persistedPrincipal(session),
      projectId: effectiveProject,
      state: state,
    );
  }

  bool _matchesLifecycle(Session session, ConversationSearchLifecycle lifecycle) => switch (lifecycle) {
    ConversationSearchLifecycle.all => true,
    ConversationSearchLifecycle.active => session.type != SessionType.archive && session.settledAt == null,
    ConversationSearchLifecycle.settled => session.type != SessionType.archive && session.settledAt != null,
    ConversationSearchLifecycle.archived => session.type == SessionType.archive,
  };

  ({String text, int start, int end}) _snippet(String content, String query) {
    final match = content.toLowerCase().indexOf(query.toLowerCase());
    if (match < 0) {
      final text = content.length <= _snippetLength ? content : '${content.substring(0, _snippetLength - 1)}…';
      return (text: text, start: 0, end: 0);
    }
    final start = (match - _snippetLength ~/ 3).clamp(0, content.length);
    final end = (start + _snippetLength).clamp(0, content.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < content.length ? '…' : '';
    return (
      text: '$prefix${content.substring(start, end)}$suffix',
      start: prefix.length + match - start,
      end: prefix.length + match - start + query.length,
    );
  }
}

final class _EligibleSession {
  const new({required this.principal, required this.projectId, required this.state});

  final String principal;
  final String? projectId;
  final ConversationState state;
}
