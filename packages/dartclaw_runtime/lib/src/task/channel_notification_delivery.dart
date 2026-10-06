import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// The page at [path] on the deployment's public [baseUrl], or `null` when it declares none.
String? publicPageUrl(String? baseUrl, String path) {
  final base = baseUrl?.trim();
  if (base == null || base.isEmpty) return null;
  return '${base.endsWith('/') ? base.substring(0, base.length - 1) : base}$path';
}

/// Delivers channel notifications for both notification subscribers: plain text,
/// or through a channel's [ThreadedNotifications] with the failure handling both
/// share.
///
/// A delivery never throws and never blocks its caller on a refusal. Warnings
/// that would repeat for every post of one subject (a run, a task) are logged
/// once until [forget] is called for it.
class ChannelNotificationDelivery {
  static final _log = Logger('ChannelNotificationDelivery');

  final Set<String> _warned = {};

  /// Sends the plain text of [notification] to [recipientId].
  Future<void> sendPlain(
    Channel channel,
    String recipientId,
    ChannelNotification notification, {
    required String subject,
  }) {
    return sendRendered(channel, recipientId, ChannelResponse(text: notification.text), subject: subject);
  }

  /// Sends an already rendered [response] to [recipientId] outside any thread.
  Future<void> sendRendered(
    Channel channel,
    String recipientId,
    ChannelResponse response, {
    required String subject,
  }) async {
    try {
      await channel.sendMessage(recipientId, response);
    } catch (error, stackTrace) {
      _log.warning('Failed to notify ${channel.type.name} recipient $recipientId for $subject', error, stackTrace);
    }
  }

  /// Opens a new thread for [subject] with [response], returning where it landed.
  ///
  /// A channel that returns no thread identity, or throws, leaves nothing to bind
  /// to: the notification then goes out as one plain send of the rendered text,
  /// which the channel has already made safe for its markup, and the miss is
  /// logged once for [subject]. Returns `null` in that case.
  Future<ThreadedPost?> sendInNewThread(
    Channel channel,
    ThreadedNotifications threads,
    String recipientId,
    ChannelResponse response, {
    required String threadKey,
    required String subject,
  }) async {
    Object? failure;
    try {
      final post = await threads.sendToNewThread(recipientId, response, threadKey: threadKey);
      if (post != null) return post;
    } catch (error) {
      failure = error;
    }
    _warnOnce(subject, 'new thread', channel, recipientId, failure);
    await sendRendered(channel, recipientId, ChannelResponse(text: response.text), subject: subject);
    return null;
  }

  /// Sends [response] into the existing thread [threadId], returning where it
  /// landed, or `null` when the send failed.
  ///
  /// A failed send is dropped, never repeated as a plain message, and logged
  /// once for [subject].
  Future<ThreadedPost?> sendInThread(
    Channel channel,
    ThreadedNotifications threads,
    String recipientId,
    ChannelResponse response, {
    required String threadId,
    required String subject,
  }) async {
    Object? failure;
    try {
      final post = await threads.sendToThread(recipientId, response, threadId: threadId);
      if (post != null) return post;
    } catch (error) {
      failure = error;
    }
    _warnOnce(subject, 'thread', channel, recipientId, failure);
    return null;
  }

  /// Lets the next miss for [subject] log again.
  void forget(String subject) => _warned.removeWhere((key) => key.startsWith('$subject|'));

  void _warnOnce(String subject, String what, Channel channel, String recipientId, Object? failure) {
    if (!_warned.add('$subject|$what')) return;
    final cause = failure == null ? 'the channel returned no $what identity' : 'failed: $failure';
    _log.warning('Could not post $subject to $what in ${channel.type.name} $recipientId ($cause)');
  }
}
