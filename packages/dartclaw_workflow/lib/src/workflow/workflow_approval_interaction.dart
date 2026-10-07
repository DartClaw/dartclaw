import 'dart:math' show Random;

import 'workflow_run.dart' show WorkflowRun;

/// Run-context key holding a run's one [WorkflowApprovalInteraction].
///
/// Private (underscore) so every context rebuild carries it, and absent from
/// the key set an approval resolution clears.
const workflowApprovalInteractionContextKey = '_approval.interaction';

/// Where an approval resolution came from.
enum WorkflowApprovalSource {
  /// A button on a chat post.
  button,

  /// An agent tool call from a chat turn.
  tool,

  /// The web UI or HTTP API.
  web,
}

/// Who resolved an approval and through which surface.
class WorkflowApprovalResolver {
  /// The surface the resolution came through.
  final WorkflowApprovalSource source;

  /// The resolver's sender ID, in the form the inbound channel path uses.
  final String? senderId;

  /// The resolver's display name, when known.
  final String? displayName;

  /// Creates a resolver.
  const new({required this.source, this.senderId, this.displayName});
}

/// How a pending approval was settled, kept on its interaction once consumed.
class WorkflowApprovalResolution {
  /// Whether the approval was approved (resume) rather than rejected (cancel).
  final bool approved;

  /// The surface the resolution came through, or `null` when none was recorded.
  final WorkflowApprovalSource? source;

  /// The resolver's sender ID, if one was recorded.
  final String? senderId;

  /// The resolver's display name, if one was recorded.
  final String? displayName;

  /// When the approval was settled.
  final DateTime at;

  /// Creates a resolution.
  const new({required this.approved, this.source, this.senderId, this.displayName, required this.at});

  /// Reads a resolution from its persisted form.
  factory fromJson(Map<String, dynamic> json) => WorkflowApprovalResolution(
    approved: json['approved'] as bool,
    source: WorkflowApprovalSource.values.asNameMap()[json['source']],
    senderId: json['senderId'] as String?,
    displayName: json['displayName'] as String?,
    at: DateTime.parse(json['at'] as String),
  );

  /// The persisted form.
  Map<String, dynamic> toJson() => {
    'approved': approved,
    'source': ?source?.name,
    'senderId': ?senderId,
    'displayName': ?displayName,
    'at': at.toIso8601String(),
  };
}

/// The chat post an approval's buttons live on.
class WorkflowApprovalPost {
  /// The channel type name the post was sent through.
  final String channelType;

  /// The recipient the post was sent to.
  final String recipientId;

  /// Identity of the posted message.
  final String messageId;

  /// Creates a post record.
  const new({required this.channelType, required this.recipientId, required this.messageId});

  /// Reads a post from its persisted form.
  factory fromJson(Map<String, dynamic> json) => WorkflowApprovalPost(
    channelType: json['channelType'] as String,
    recipientId: json['recipientId'] as String,
    messageId: json['messageId'] as String,
  );

  /// The persisted form.
  Map<String, dynamic> toJson() => {'channelType': channelType, 'recipientId': recipientId, 'messageId': messageId};
}

/// The durable record that lets one chat post resolve one pending approval once.
///
/// A run holds a single record, overwritten by each issue and kept after
/// resolution so the post it names can still be found.
class WorkflowApprovalInteraction {
  /// 128-bit nonce width, in bytes.
  static const nonceBytes = 16;

  /// The approval step the record was issued for.
  final String stepId;

  /// The hex-encoded 128-bit secure-random nonce a click must carry.
  final String nonce;

  /// When the record was issued.
  final DateTime issuedAt;

  /// The post the buttons were sent on, or `null` until one is bound.
  final WorkflowApprovalPost? post;

  /// How the approval was settled, or `null` while it is still pending.
  final WorkflowApprovalResolution? resolution;

  /// Creates a record.
  const new({required this.stepId, required this.nonce, required this.issuedAt, this.post, this.resolution});

  /// A fresh record for [stepId] with a secure-random nonce.
  factory issue(String stepId, {Random? random}) {
    final source = random ?? Random.secure();
    final nonce = [for (var i = 0; i < nonceBytes; i++) source.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    return WorkflowApprovalInteraction(stepId: stepId, nonce: nonce, issuedAt: DateTime.now());
  }

  /// The record a run carries, or `null` when none was issued.
  static WorkflowApprovalInteraction? of(WorkflowRun run) => fromContext(run.contextJson);

  /// The record carried by [contextJson], or `null` when none was issued.
  static WorkflowApprovalInteraction? fromContext(Map<String, dynamic> contextJson) {
    final raw = contextJson[workflowApprovalInteractionContextKey];
    return raw is Map ? WorkflowApprovalInteraction.fromJson(Map<String, dynamic>.from(raw)) : null;
  }

  /// Reads a record from its persisted form.
  factory fromJson(Map<String, dynamic> json) => WorkflowApprovalInteraction(
    stepId: json['stepId'] as String,
    nonce: json['nonce'] as String,
    issuedAt: DateTime.parse(json['issuedAt'] as String),
    post: json['post'] is Map ? WorkflowApprovalPost.fromJson(Map<String, dynamic>.from(json['post'] as Map)) : null,
    resolution: json['resolution'] is Map
        ? WorkflowApprovalResolution.fromJson(Map<String, dynamic>.from(json['resolution'] as Map))
        : null,
  );

  /// Whether the approval was already settled.
  bool get isResolved => resolution != null;

  /// This record with [post] bound.
  WorkflowApprovalInteraction withPost(WorkflowApprovalPost post) =>
      WorkflowApprovalInteraction(stepId: stepId, nonce: nonce, issuedAt: issuedAt, post: post, resolution: resolution);

  /// This record consumed by [resolution].
  WorkflowApprovalInteraction consumed(WorkflowApprovalResolution resolution) =>
      WorkflowApprovalInteraction(stepId: stepId, nonce: nonce, issuedAt: issuedAt, post: post, resolution: resolution);

  /// The persisted form.
  Map<String, dynamic> toJson() => {
    'stepId': stepId,
    'nonce': nonce,
    'issuedAt': issuedAt.toIso8601String(),
    'post': ?post?.toJson(),
    'resolution': ?resolution?.toJson(),
  };
}

/// What a resolution must match for the interaction to accept it: the step,
/// the nonce and the post the click came from.
class WorkflowApprovalExpectation {
  /// The approval step the click names.
  final String stepId;

  /// The nonce the click carries.
  final String nonce;

  /// The channel type the click arrived on.
  final String channelType;

  /// Identity of the message the click landed on.
  final String messageId;

  /// Creates an expectation.
  const new({required this.stepId, required this.nonce, required this.channelType, required this.messageId});
}

/// Why a resolution carrying a resolver or an expectation was refused.
enum WorkflowApprovalRefusal {
  /// The run is not waiting at that approval.
  notPending,

  /// The approval was already resolved.
  alreadyResolved,

  /// The nonce, step or post does not match the live interaction.
  invalidNonce,
}

/// A refused resolution. Thrown instead of a [StateError] whenever the caller
/// named a resolver or an expectation, so an adapter can render the reason.
class WorkflowApprovalRefused implements Exception {
  /// Why the resolution was refused.
  final WorkflowApprovalRefusal reason;

  /// The text the same refusal reads as for a caller that named neither.
  final String message;

  /// Creates a refusal.
  const new(this.reason, this.message);

  @override
  String toString() => 'WorkflowApprovalRefused(${reason.name}): $message';
}
