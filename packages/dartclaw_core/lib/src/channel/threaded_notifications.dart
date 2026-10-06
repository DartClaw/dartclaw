import 'channel.dart';

/// What a [ChannelNotification] reports on.
enum ChannelNotificationKind {
  /// A task's status change.
  task,

  /// A workflow run's lifecycle step.
  run,
}

/// A channel-neutral notification a subscriber hands to a channel's
/// [ThreadedNotifications.render], which owns every native card or block.
class ChannelNotification {
  /// What the notification reports on.
  final ChannelNotificationKind kind;

  /// Identifier of the task or run reported on.
  final String id;

  /// Plain-text rendering, delivered as is by a channel without the capability
  /// and as the fallback text beside a native card.
  final String text;

  /// Heading naming the task, or the workflow for a run.
  final String title;

  /// Status name (a task status, or a run lifecycle event).
  final String status;

  /// Supporting text, such as a task description or what an approval gates.
  final String? body;

  /// Failure detail, shown when present.
  final String? error;

  /// Who asked for the work, shown when present.
  final String? requestedBy;

  /// Labelled values shown in order, such as the workflow, run and step.
  final Map<String, String> facts;

  /// When the reported work was created.
  final DateTime? createdAt;

  /// When the reported status was reached.
  final DateTime? updatedAt;

  /// Whether the rendering carries accept and reject actions for [id].
  final bool reviewActions;

  /// Creates a notification.
  const new({
    required this.kind,
    required this.id,
    required this.text,
    required this.title,
    required this.status,
    this.body,
    this.error,
    this.requestedBy,
    this.facts = const {},
    this.createdAt,
    this.updatedAt,
    this.reviewActions = false,
  });
}

/// Where a notification landed: the thread and the message within it.
class ThreadedPost {
  /// Identity of the thread, as [ThreadedNotifications.extractThread] reads it
  /// from an inbound message in that thread.
  final String threadId;

  /// Identity of the posted message.
  final String messageId;

  /// Creates a post record.
  const new({required this.threadId, required this.messageId});
}

/// The one declaration that a [Channel] threads.
///
/// A channel exposes it through [Channel.threadedNotifications]; its presence is
/// the only answer to whether the channel can hold a thread binding, and
/// every thread reader and notification sender goes through it.
abstract interface class ThreadedNotifications {
  /// The thread identity of an inbound message carrying [metadata], or `null`
  /// when the message is not in a thread.
  String? extractThread(Map<String, dynamic> metadata);

  /// Renders [notification] into a response carrying this channel's native
  /// card or blocks beside its plain text.
  ChannelResponse render(ChannelNotification notification);

  /// Posts [response] to [recipientId] as the first message of a new thread
  /// keyed [threadKey], returning where it landed, or `null` when the channel
  /// reports no thread identity or refuses the post.
  Future<ThreadedPost?> sendToNewThread(String recipientId, ChannelResponse response, {required String threadKey});

  /// Posts [response] to [recipientId] into the existing thread [threadId],
  /// returning where it landed, or `null` when the channel refuses the post.
  Future<ThreadedPost?> sendToThread(String recipientId, ChannelResponse response, {required String threadId});
}
