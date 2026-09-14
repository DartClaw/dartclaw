enum SubmissionCommitState { preparing, committed, integrityFailed }

enum ConversationWorkState {
  accepted,
  queued,
  held,
  dispatching,
  running,
  stopping,
  uncertain,
  completed,
  failed,
  cancelled,
  removed,
}

enum ConversationRecordKind { tool, approval }

enum ConversationRecordState {
  running,
  succeeded,
  failed,
  blocked,
  pending,
  resolving,
  approved,
  rejected,
  expired,
  unavailable,
}

final class ConversationDisplayRecord {
  static const _unset = Object();

  final String id;
  final String attemptId;
  final String turnId;
  final ConversationRecordKind kind;
  final ConversationRecordState state;
  final String label;
  final String? arguments;
  final String? result;
  final bool isTruncated;
  final int? elapsedMs;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const new({
    required this.id,
    required this.attemptId,
    required this.turnId,
    required this.kind,
    required this.state,
    required this.label,
    this.arguments,
    this.result,
    this.isTruncated = false,
    this.elapsedMs,
    this.expiresAt,
    required this.createdAt,
    required this.updatedAt,
  });

  ConversationDisplayRecord copyWith({
    ConversationRecordState? state,
    Object? result = _unset,
    bool? isTruncated,
    Object? elapsedMs = _unset,
    DateTime? updatedAt,
  }) => ConversationDisplayRecord(
    id: id,
    attemptId: attemptId,
    turnId: turnId,
    kind: kind,
    state: state ?? this.state,
    label: label,
    arguments: arguments,
    result: identical(result, _unset) ? this.result : result as String?,
    isTruncated: isTruncated ?? this.isTruncated,
    elapsedMs: identical(elapsedMs, _unset) ? this.elapsedMs : elapsedMs as int?,
    expiresAt: expiresAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'attemptId': attemptId,
    'turnId': turnId,
    'kind': kind.name,
    'state': state.name,
    'label': label,
    if (arguments != null) 'arguments': arguments,
    if (result != null) 'result': result,
    'isTruncated': isTruncated,
    if (elapsedMs != null) 'elapsedMs': elapsedMs,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory fromJson(Map<String, dynamic> json) => ConversationDisplayRecord(
    id: json['id'] as String,
    attemptId: json['attemptId'] as String,
    turnId: json['turnId'] as String,
    kind: ConversationRecordKind.values.byName(json['kind'] as String),
    state: ConversationRecordState.values.byName(json['state'] as String),
    label: json['label'] as String,
    arguments: json['arguments'] as String?,
    result: json['result'] as String?,
    isTruncated: json['isTruncated'] as bool? ?? false,
    elapsedMs: json['elapsedMs'] as int?,
    expiresAt: json['expiresAt'] == null ? null : DateTime.parse(json['expiresAt'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

enum ConversationBranchKind { retry, edit, fork }

final class ConversationBranchLink {
  final String mutationId;
  final ConversationBranchKind kind;
  final String sourceSessionId;
  final String sourceMessageId;
  final String? sourceAttemptId;
  final String destinationSessionId;
  final String destinationMessageId;
  final String? destinationAttemptId;
  final bool completed;
  final DateTime createdAt;

  const new({
    required this.mutationId,
    required this.kind,
    required this.sourceSessionId,
    required this.sourceMessageId,
    this.sourceAttemptId,
    required this.destinationSessionId,
    required this.destinationMessageId,
    this.destinationAttemptId,
    this.completed = true,
    required this.createdAt,
  });

  ConversationBranchLink copyWith({String? destinationMessageId, String? destinationAttemptId, bool? completed}) =>
      ConversationBranchLink(
        mutationId: mutationId,
        kind: kind,
        sourceSessionId: sourceSessionId,
        sourceMessageId: sourceMessageId,
        sourceAttemptId: sourceAttemptId,
        destinationSessionId: destinationSessionId,
        destinationMessageId: destinationMessageId ?? this.destinationMessageId,
        destinationAttemptId: destinationAttemptId ?? this.destinationAttemptId,
        completed: completed ?? this.completed,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
    'mutationId': mutationId,
    'kind': kind.name,
    'sourceSessionId': sourceSessionId,
    'sourceMessageId': sourceMessageId,
    if (sourceAttemptId != null) 'sourceAttemptId': sourceAttemptId,
    'destinationSessionId': destinationSessionId,
    'destinationMessageId': destinationMessageId,
    if (destinationAttemptId != null) 'destinationAttemptId': destinationAttemptId,
    'completed': completed,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory fromJson(Map<String, dynamic> json) => ConversationBranchLink(
    mutationId: json['mutationId'] as String,
    kind: ConversationBranchKind.values.byName(json['kind'] as String),
    sourceSessionId: json['sourceSessionId'] as String,
    sourceMessageId: json['sourceMessageId'] as String,
    sourceAttemptId: json['sourceAttemptId'] as String?,
    destinationSessionId: json['destinationSessionId'] as String,
    destinationMessageId: json['destinationMessageId'] as String,
    destinationAttemptId: json['destinationAttemptId'] as String?,
    completed: json['completed'] as bool? ?? true,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

final class ConversationAttachmentManifest {
  final String id;
  final String filename;
  final String mediaType;
  final int size;
  final String digest;

  const new({
    required this.id,
    required this.filename,
    required this.mediaType,
    required this.size,
    required this.digest,
  });

  Map<String, Object> toJson() => {
    'id': id,
    'filename': filename,
    'mediaType': mediaType,
    'size': size,
    'digest': digest,
  };

  factory fromJson(Map<String, dynamic> json) => ConversationAttachmentManifest(
    id: json['id'] as String,
    filename: json['filename'] as String,
    mediaType: json['mediaType'] as String,
    size: json['size'] as int,
    digest: json['digest'] as String,
  );
}

final class ConversationSubmissionClaim {
  static const _unset = Object();

  final String submissionId;
  final String revisionId;
  final String? replacesRevisionId;
  final String messageId;
  final String? attemptId;
  final String? queueId;
  final String payloadDigest;
  final String message;
  final List<Map<String, dynamic>> references;
  final List<ConversationAttachmentManifest> attachments;
  final SubmissionCommitState commitState;
  final ConversationWorkState workState;
  final String? turnId;
  final String? detail;
  final DateTime createdAt;
  final DateTime updatedAt;

  new({
    required this.submissionId,
    required this.revisionId,
    this.replacesRevisionId,
    required this.messageId,
    this.attemptId,
    this.queueId,
    required this.payloadDigest,
    required this.message,
    List<Map<String, dynamic>> references = const [],
    List<ConversationAttachmentManifest> attachments = const [],
    required this.commitState,
    required this.workState,
    this.turnId,
    this.detail,
    required this.createdAt,
    required this.updatedAt,
  }) : references = List.unmodifiable(references.map((item) => Map<String, dynamic>.unmodifiable(item))),
       attachments = List.unmodifiable(attachments);

  bool get isQueueItem => queueId != null && workState != ConversationWorkState.removed;

  ConversationSubmissionClaim copyWith({
    String? revisionId,
    Object? replacesRevisionId = _unset,
    String? payloadDigest,
    String? message,
    List<Map<String, dynamic>>? references,
    List<ConversationAttachmentManifest>? attachments,
    Object? attemptId = _unset,
    Object? queueId = _unset,
    SubmissionCommitState? commitState,
    ConversationWorkState? workState,
    Object? turnId = _unset,
    Object? detail = _unset,
    DateTime? updatedAt,
  }) => ConversationSubmissionClaim(
    submissionId: submissionId,
    revisionId: revisionId ?? this.revisionId,
    replacesRevisionId: identical(replacesRevisionId, _unset) ? this.replacesRevisionId : replacesRevisionId as String?,
    messageId: messageId,
    attemptId: identical(attemptId, _unset) ? this.attemptId : attemptId as String?,
    queueId: identical(queueId, _unset) ? this.queueId : queueId as String?,
    payloadDigest: payloadDigest ?? this.payloadDigest,
    message: message ?? this.message,
    references: references ?? this.references,
    attachments: attachments ?? this.attachments,
    commitState: commitState ?? this.commitState,
    workState: workState ?? this.workState,
    turnId: identical(turnId, _unset) ? this.turnId : turnId as String?,
    detail: identical(detail, _unset) ? this.detail : detail as String?,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'submissionId': submissionId,
    'revisionId': revisionId,
    if (replacesRevisionId != null) 'replacesRevisionId': replacesRevisionId,
    'messageId': messageId,
    if (attemptId != null) 'attemptId': attemptId,
    if (queueId != null) 'queueId': queueId,
    'payloadDigest': payloadDigest,
    'message': message,
    'references': references,
    'attachments': attachments.map((attachment) => attachment.toJson()).toList(growable: false),
    'commitState': commitState.name,
    'workState': workState.name,
    if (turnId != null) 'turnId': turnId,
    if (detail != null) 'detail': detail,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory fromJson(Map<String, dynamic> json) => ConversationSubmissionClaim(
    submissionId: json['submissionId'] as String,
    revisionId: json['revisionId'] as String,
    replacesRevisionId: json['replacesRevisionId'] as String?,
    messageId: json['messageId'] as String,
    attemptId: json['attemptId'] as String?,
    queueId: json['queueId'] as String?,
    payloadDigest: json['payloadDigest'] as String,
    message: json['message'] as String,
    references: (json['references'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false),
    attachments: (json['attachments'] as List<dynamic>? ?? const [])
        .map((item) => ConversationAttachmentManifest.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false),
    commitState: SubmissionCommitState.values.byName(json['commitState'] as String),
    workState: ConversationWorkState.values.byName(json['workState'] as String),
    turnId: json['turnId'] as String?,
    detail: json['detail'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

final class ConversationState {
  final int revision;
  final List<ConversationSubmissionClaim> submissions;
  final List<ConversationDisplayRecord> records;
  final List<ConversationBranchLink> branches;

  new({
    this.revision = 0,
    List<ConversationSubmissionClaim> submissions = const [],
    List<ConversationDisplayRecord> records = const [],
    List<ConversationBranchLink> branches = const [],
  }) : submissions = List.unmodifiable(submissions),
       records = List.unmodifiable(records),
       branches = List.unmodifiable(branches);

  ConversationSubmissionClaim? findSubmission(String submissionId) {
    for (final submission in submissions) {
      if (submission.submissionId == submissionId) return submission;
    }
    return null;
  }

  ConversationSubmissionClaim? findQueueItem(String queueId) {
    for (final submission in submissions) {
      if (submission.queueId == queueId && submission.workState != ConversationWorkState.removed) return submission;
    }
    return null;
  }

  List<ConversationSubmissionClaim> get queue =>
      submissions.where((submission) => submission.isQueueItem).toList(growable: false)
        ..sort((left, right) => left.createdAt.compareTo(right.createdAt));

  bool includesMessage(String messageId, {String? activeMessageId}) {
    final submission = submissions.where((item) => item.messageId == messageId).firstOrNull;
    if (submission == null || messageId == activeMessageId) return true;
    return switch (submission.workState) {
      ConversationWorkState.dispatching ||
      ConversationWorkState.running ||
      ConversationWorkState.stopping ||
      ConversationWorkState.uncertain ||
      ConversationWorkState.completed ||
      ConversationWorkState.failed ||
      ConversationWorkState.cancelled => true,
      ConversationWorkState.accepted ||
      ConversationWorkState.queued ||
      ConversationWorkState.held ||
      ConversationWorkState.removed => false,
    };
  }

  ConversationState put(ConversationSubmissionClaim submission) {
    final next = [...submissions];
    final index = next.indexWhere((item) => item.submissionId == submission.submissionId);
    if (index == -1) {
      next.add(submission);
    } else {
      next[index] = submission;
    }
    return ConversationState(revision: revision + 1, submissions: next, records: records, branches: branches);
  }

  ConversationDisplayRecord? findRecord(String id) => records.where((record) => record.id == id).firstOrNull;

  ConversationState putRecord(ConversationDisplayRecord record) {
    final next = [...records];
    final index = next.indexWhere((item) => item.id == record.id);
    if (index == -1) {
      next.add(record);
    } else {
      next[index] = record;
    }
    return ConversationState(revision: revision + 1, submissions: submissions, records: next, branches: branches);
  }

  ConversationBranchLink? findBranch(String mutationId) =>
      branches.where((branch) => branch.mutationId == mutationId).firstOrNull;

  ConversationState putBranch(ConversationBranchLink branch) {
    final existing = findBranch(branch.mutationId);
    if (existing != null &&
        existing.kind == branch.kind &&
        existing.sourceSessionId == branch.sourceSessionId &&
        existing.sourceMessageId == branch.sourceMessageId &&
        existing.sourceAttemptId == branch.sourceAttemptId &&
        existing.destinationSessionId == branch.destinationSessionId &&
        existing.destinationMessageId == branch.destinationMessageId &&
        existing.destinationAttemptId == branch.destinationAttemptId &&
        existing.completed == branch.completed) {
      return this;
    }
    return ConversationState(
      revision: revision + 1,
      submissions: submissions,
      records: records,
      branches: [...branches.where((item) => item.mutationId != branch.mutationId), branch],
    );
  }

  Map<String, Object> toJson() => {
    'revision': revision,
    'submissions': submissions.map((submission) => submission.toJson()).toList(growable: false),
    'records': records.map((record) => record.toJson()).toList(growable: false),
    'branches': branches.map((branch) => branch.toJson()).toList(growable: false),
  };

  factory fromJson(Map<String, dynamic> json) => ConversationState(
    revision: json['revision'] as int? ?? 0,
    submissions: (json['submissions'] as List<dynamic>? ?? const [])
        .map((item) => ConversationSubmissionClaim.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false),
    records: (json['records'] as List<dynamic>? ?? const [])
        .map((item) => ConversationDisplayRecord.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false),
    branches: (json['branches'] as List<dynamic>? ?? const [])
        .map((item) => ConversationBranchLink.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false),
  );
}
