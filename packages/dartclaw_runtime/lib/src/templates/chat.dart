import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ConversationDisplayRecord,
        ConversationRecordKind,
        ConversationRecordState,
        ConversationState,
        ConversationWorkState;

import 'components.dart';
import 'loader.dart';
import 'session_info.dart' show sessionTurnStatusMountView;

// Patterns for special assistant messages stored by TurnManager.
final _guardBlockPattern = RegExp(r'^\[(?:Response )?[Bb]locked by guard: (.+)\]$', dotAll: true);
final _turnFailedPattern = RegExp(r'^\[Turn failed(?::\s*(.+))?\]$', dotAll: true);

/// Message type classification result.
enum MessageType { user, assistant, guardBlock, turnFailed }

/// Classified message with type and extracted detail (for guard-block / turn-failed).
typedef ClassifiedMessage = ({
  String id,
  String role,
  String content,
  MessageType messageType,
  String? detail,
  String? senderName,
  String? metadata,
  DateTime? createdAt,
  int? cursor,
});

/// Classifies a raw message into one of the four message types.
///
/// User messages are always [MessageType.user]. Assistant messages are checked
/// against guard-block and turn-failed patterns; unmatched ones are
/// [MessageType.assistant].
///
/// [senderName] is an optional display name for user messages — shown as a
/// prefix in the task detail chat view when present (e.g. "Alice: fix the
/// login bug"). Pass `null` for web/operator turns.
ClassifiedMessage classifyMessage({
  required String id,
  required String role,
  required String content,
  String? metadata,
  String? senderName,
  DateTime? createdAt,
  int? cursor,
}) {
  if (role == 'user') {
    return (
      id: id,
      role: role,
      content: content,
      messageType: MessageType.user,
      detail: null,
      senderName: senderName,
      metadata: metadata,
      createdAt: createdAt,
      cursor: cursor,
    );
  }

  final guardMatch = _guardBlockPattern.firstMatch(content);
  if (guardMatch != null) {
    return (
      id: id,
      role: role,
      content: content,
      messageType: MessageType.guardBlock,
      detail: guardMatch.group(1) ?? content,
      senderName: null,
      metadata: metadata,
      createdAt: createdAt,
      cursor: cursor,
    );
  }

  final failedMatch = _turnFailedPattern.firstMatch(content);
  if (failedMatch != null) {
    return (
      id: id,
      role: role,
      content: content,
      messageType: MessageType.turnFailed,
      detail: failedMatch.group(1),
      senderName: null,
      metadata: metadata,
      createdAt: createdAt,
      cursor: cursor,
    );
  }

  return (
    id: id,
    role: role,
    content: content,
    messageType: MessageType.assistant,
    detail: null,
    senderName: null,
    metadata: metadata,
    createdAt: createdAt,
    cursor: cursor,
  );
}

/// Renders a list of messages as HTML fragments.
/// Returns [emptyStateTemplate] when [messages] is empty.
///
/// Each message should already be classified via [classifyMessage].
String messagesHtmlFragment(
  List<ClassifiedMessage> messages, {
  ConversationState? conversationState,
  bool Function(ConversationDisplayRecord record)? approvalAvailable,
}) {
  if (messages.isEmpty) {
    return promptHeroTemplate(
      titleHtml: '<span class="text-gradient">Welcome back</span>',
      sub: 'Send a message to start the conversation.',
      modifiers: 'prompt-hero--center prompt-hero--fill',
      useMascot: true,
    );
  }

  final src = templateLoader.source('chat');
  final trellis = templateLoader.trellis;
  final buffer = StringBuffer();
  for (final m in messages) {
    final submission = conversationState?.submissions.where((item) => item.messageId == m.id).firstOrNull;
    final terminal =
        submission != null &&
        (submission.workState == ConversationWorkState.completed ||
            submission.workState == ConversationWorkState.failed ||
            submission.workState == ConversationWorkState.cancelled);
    final timestamp = m.createdAt?.toLocal();
    final common = {
      'messageId': m.id,
      'messageDomId': 'message-${m.id}',
      'cursor': m.cursor?.toString(),
      'timestamp': timestamp == null ? '' : _shortTimestamp(timestamp),
      'fullTimestamp': m.createdAt?.toUtc().toIso8601String() ?? '',
      'hasTimestamp': timestamp != null,
      'sourceAttemptId': submission?.attemptId ?? '',
      'hasSourceAttempt': submission?.attemptId != null,
      'editAvailable': m.messageType == MessageType.user && terminal,
      'retryAvailable':
          submission?.workState == ConversationWorkState.failed ||
          submission?.workState == ConversationWorkState.cancelled,
      'forkAvailable': submission == null || terminal,
      'historyHtml': conversationState == null
          ? ''
          : _historyForMessage(m, conversationState, approvalAvailable ?? (_) => false),
    };
    switch (m.messageType) {
      case MessageType.user:
        buffer.write(
          trellis.renderFragment(
            src,
            fragment: 'userMessage',
            context: {
              'content': m.content,
              'senderName': m.senderName,
              'hasSenderName': m.senderName != null && m.senderName!.isNotEmpty,
              'richInputHtml': richInputHtmlFromMessageMetadata(m.metadata),
              ...common,
            },
          ),
        );
      case MessageType.assistant:
        buffer.write(
          trellis.renderFragment(src, fragment: 'assistantMessage', context: {'content': m.content, ...common}),
        );
      case MessageType.guardBlock:
        buffer.write(trellis.renderFragment(src, fragment: 'guardBlock', context: {'detail': m.detail, ...common}));
      case MessageType.turnFailed:
        buffer.write(trellis.renderFragment(src, fragment: 'turnFailed', context: {'detail': m.detail, ...common}));
    }
  }
  return buffer.toString();
}

String _historyForMessage(
  ClassifiedMessage message,
  ConversationState state,
  bool Function(ConversationDisplayRecord record) approvalAvailable,
) {
  final submission = state.submissions.where((item) => item.messageId == message.id).firstOrNull;
  final buffer = StringBuffer();
  if (submission?.attemptId case final attemptId?) {
    final records = state.records.where((item) => item.attemptId == attemptId).toList(growable: false);
    if (records.isNotEmpty) buffer.write('<div class="well-flush history-records">');
    for (final record in records) {
      final label = htmlEscape.convert(record.label);
      final recordId = htmlEscape.convert(record.id);
      final stateName = htmlEscape.convert(record.state.name);
      final arguments = htmlEscape.convert(record.arguments ?? 'No retained arguments');
      final result = htmlEscape.convert(record.result ?? _recordFallback(record));
      if (record.kind == ConversationRecordKind.tool) {
        final presentation = _toolPresentation(record.state);
        final detail = record.isTruncated ? '${presentation.label} · retained output truncated' : presentation.label;
        final duration = record.elapsedMs == null ? '' : '${(record.elapsedMs! / 1000).toStringAsFixed(1)}s';
        buffer.write(
          '<details class="tool-call ${presentation.className}" data-tool-id="$recordId" data-state="$stateName">'
          '<summary class="tool-call-summary"><span class="tool-call-name">$label</span>'
          '<span class="tool-call-detail">${htmlEscape.convert(detail)}</span>'
          '${duration.isEmpty ? '' : '<span class="tool-call-time">$duration</span>'}'
          '${record.state == ConversationRecordState.running ? '<span class="scan-bar"></span>' : ''}</summary>'
          '<div class="tool-call-body"><div class="tool-call-io"><span class="tool-call-io-label">args</span>'
          '<div class="well-deep"><pre><code>$arguments</code></pre></div></div>'
          '<div class="tool-call-io"><span class="tool-call-io-label">result</span>'
          '<div class="well-deep"><pre><code>$result</code></pre></div></div></div></details>',
        );
      } else {
        final pending = record.state == ConversationRecordState.pending && approvalAvailable(record);
        final approval = record.state == ConversationRecordState.pending && !pending
            ? (className: 'approval-card--expired', label: 'Approval unavailable', iconClass: 'icon-clock')
            : _approvalPresentation(record.state);
        final displayStateName = record.state == ConversationRecordState.pending && !pending
            ? 'unavailable'
            : stateName;
        buffer.write(
          '<section class="card approval-card ${approval.className}" data-approval-request-id="$recordId" '
          'data-state="$displayStateName" tabindex="-1" aria-label="Runtime approval: ${htmlEscape.convert(approval.label)}">'
          '<span hidden data-approval-attempt-id="${htmlEscape.convert(record.attemptId)}" data-approval-turn-id="${htmlEscape.convert(record.turnId)}"></span>'
          '<div class="card-header">${pending ? '<span class="status-dot status-dot--attention" aria-hidden="true"></span>' : ''}'
          '$label<span class="approval-card-meta">${htmlEscape.convert(approval.label)}</span></div>'
          '<div class="card-body"><div class="well-content approval-card-plan"><p>$arguments</p></div></div>'
          '${pending ? '<div class="card-footer approval-card-actions"><button type="button" class="btn btn-primary" data-approval-decision="approve">Approve exact request</button><button type="button" class="btn btn-danger" data-approval-decision="reject">Reject exact request</button></div>' : '<div class="card-footer approval-card-resolution"><span class="icon ${approval.iconClass}" aria-hidden="true"></span>${htmlEscape.convert(approval.label)}</div>'}'
          '</section>',
        );
      }
    }
    if (records.isNotEmpty) buffer.write('</div>');
  }
  final sourceBranches = state.branches.where((branch) => branch.sourceMessageId == message.id);
  for (final branch in sourceBranches) {
    buffer.write(
      '<a class="message-lineage" href="/sessions/${htmlEscape.convert(branch.destinationSessionId)}" '
      'data-branch-kind="${branch.kind.name}">${htmlEscape.convert(branch.kind.name)} branch</a>',
    );
  }
  return buffer.toString();
}

String _recordFallback(ConversationDisplayRecord record) => switch (record.state) {
  ConversationRecordState.running ||
  ConversationRecordState.pending ||
  ConversationRecordState.resolving => 'In progress',
  ConversationRecordState.blocked => 'Blocked before completion',
  _ => 'No retained result',
};

({String className, String label}) _toolPresentation(ConversationRecordState state) => switch (state) {
  ConversationRecordState.running => (className: 'tool-call--pending', label: 'Running'),
  ConversationRecordState.succeeded => (className: 'tool-call--success', label: 'Succeeded'),
  ConversationRecordState.failed => (className: 'tool-call--error', label: 'Failed'),
  ConversationRecordState.blocked => (className: 'tool-call--blocked', label: 'Blocked'),
  _ => (className: 'tool-call--error', label: 'Invalid tool state'),
};

({String className, String label, String iconClass}) _approvalPresentation(ConversationRecordState state) =>
    switch (state) {
      ConversationRecordState.pending => (
        className: 'approval-card--waiting',
        label: 'Waiting for approval',
        iconClass: 'icon-clock',
      ),
      ConversationRecordState.resolving => (
        className: 'approval-card--expired',
        label: 'Resolution in progress',
        iconClass: 'icon-clock',
      ),
      ConversationRecordState.approved => (
        className: 'approval-card--approved',
        label: 'Approved',
        iconClass: 'icon-check',
      ),
      ConversationRecordState.rejected => (
        className: 'approval-card--rejected',
        label: 'Rejected',
        iconClass: 'icon-circle-x',
      ),
      ConversationRecordState.expired => (
        className: 'approval-card--expired',
        label: 'Expired',
        iconClass: 'icon-clock',
      ),
      _ => (className: 'approval-card--expired', label: 'Approval unavailable', iconClass: 'icon-clock'),
    };

String _shortTimestamp(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

/// Renders durable rich input chips attached to a stored user message.
String? richInputHtmlFromMessageMetadata(String? metadata) {
  if (metadata == null || metadata.trim().isEmpty) return null;
  final decoded = _tryDecodeJson(metadata);
  if (decoded is! Map<String, dynamic>) return null;
  return richInputHtmlFromMetadataMap(decoded);
}

String? richInputHtmlFromMetadataMap(Map<String, dynamic>? metadata) {
  if (metadata == null) return null;
  final attachments = (metadata['attachments'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
  final references = (metadata['references'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
  if (attachments.isEmpty && references.isEmpty) return null;

  final buffer = StringBuffer('<div class="msg-rich-input chip-row" aria-label="Rich input context">');
  for (final attachment in attachments) {
    final filename = htmlEscape.convert((attachment['filename'] as String?) ?? 'attachment');
    final state = htmlEscape.convert((attachment['state'] as String?) ?? 'ready');
    buffer.write(
      '<span class="chip"><span class="chip-name">$filename</span><span class="chip-meta">$state</span></span>',
    );
  }
  for (final reference in references) {
    final type = htmlEscape.convert((reference['type'] as String?) ?? 'reference');
    final label = htmlEscape.convert((reference['label'] as String?) ?? (reference['id'] as String?) ?? 'reference');
    buffer.write(
      '<span class="chip chip--ref"><span class="chip-name">@$label</span><span class="chip-meta">$type</span></span>',
    );
  }
  buffer.write('</div>');
  return buffer.toString();
}

Object? _tryDecodeJson(String value) {
  try {
    return jsonDecode(value);
  } catch (_) {
    return null;
  }
}

/// Renders the full chat area, including the messages list and input form.
/// [chatNoticeHtml] is optional pre-rendered one-shot session-notice HTML
/// (worker crash, turn recovery) placed before the messages. Restart state is
/// shell chrome and is rendered into the topbar's restart slot, not here.
String chatAreaTemplate({
  required String sessionId,
  required String messagesHtml,
  bool isStreaming = false,
  bool hasTitle = false,
  String chatNoticeHtml = '',
  bool readOnly = false,
  int? earliestCursor,
  bool hasEarlierMessages = false,
  bool autofocus = false,
  bool isNewChatDraft = false,
  Map<String, dynamic>? turnStatus,
  String? targetMessageId,
  Map<String, dynamic>? effectiveContext,
}) {
  final placeholder = isStreaming ? 'Agent is responding...' : 'Type a message...';
  final inputDisabled = isStreaming || readOnly;
  final turnStatusView = sessionTurnStatusMountView(turnStatus, fallbackSessionId: sessionId);

  // Trellis auto-escapes attribute values set via tl:attr, so pass raw sessionId.
  return templateLoader.trellis.renderFragment(
    templateLoader.source('chat'),
    fragment: 'chatArea',
    context: {
      'sessionId': sessionId,
      'hasTitle': hasTitle ? 'true' : 'false',
      'newChatDraft': isNewChatDraft ? 'true' : null,
      'targetMessageId': targetMessageId,
      'earliestCursor': earliestCursor?.toString(),
      'loadEarlierHidden': hasEarlierMessages ? null : true,
      'chatNoticeHtml': chatNoticeHtml.isNotEmpty ? chatNoticeHtml : null,
      'messagesHtml': messagesHtml,
      'turnStatus': turnStatusView,
      'hasTurnStatus': true,
      'readOnly': readOnly,
      'sendUrl': '/api/sessions/$sessionId/send',
      'placeholder': placeholder,
      'inputDisabled': inputDisabled ? true : null,
      'autofocus': autofocus && !inputDisabled ? true : null,
      'effectiveContext': effectiveContext,
      'hasEffectiveContext': effectiveContext != null,
    },
  );
}
