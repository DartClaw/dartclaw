import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'channel.dart';
import 'dm_access.dart';

/// Controls whether a group message should be processed based on mention/reply status.
class MentionGating {
  /// Whether group messages must explicitly mention the bot to be processed.
  final bool requireMention;

  final List<RegExp> _patterns;

  /// Bot identifier matched against [ChannelMessage.mentionedJids].
  String ownJid;

  /// Creates mention-gating rules for group message processing.
  new({required this.requireMention, required List<String> mentionPatterns, required this.ownJid})
    : _patterns = mentionPatterns.map(RegExp.new).toList();

  /// Whether the given message should be processed.
  ///
  /// DM messages (no groupJid) always return true.
  /// Group messages require a mention or reply-to-bot when [requireMention] is true.
  bool shouldProcess(ChannelMessage message) {
    if (message.groupJid == null) return true;
    if (!requireMention) return true;
    if (message.mentionedJids.contains(ownJid)) return true;

    for (final pattern in _patterns) {
      if (pattern.hasMatch(message.text)) return true;
    }

    return false;
  }
}

/// Outcome of [ChannelInboundGate.evaluate], naming the stage that admitted or dropped the message.
enum ChannelInboundDecision {
  /// The message cleared every gate and may be dispatched.
  admitted,

  /// A direct message whose sender the DM access controller rejects.
  dmDenied,

  /// A direct message rejected while the controller is in pairing mode; the caller owns the pairing effect.
  dmPairingRequired,

  /// A group message while group access is disabled.
  groupAccessDisabled,

  /// A group message whose group is absent from the group allowlist.
  groupNotAllowlisted,

  /// A group message carrying no bot mention while mention gating requires one.
  mentionRequired,
}

/// Shared inbound access decision for every channel: DM access, then group access, then mention gating.
///
/// Pure — logs nothing, performs no I/O, mutates no collaborator. Drop logging, pairing requests and
/// channel-specific replies stay at the call site, so each channel keeps its own observable behaviour.
abstract final class ChannelInboundGate {
  /// Evaluates [message] against the channel's access configuration.
  ///
  /// A null [dmAccess] or [mentionGating] admits at that stage rather than denying.
  /// [groupAllowlist] is matched against [ChannelMessage.groupJid].
  static ChannelInboundDecision evaluate(
    ChannelMessage message, {
    required DmAccessController? dmAccess,
    required MentionGating? mentionGating,
    required GroupAccessMode groupAccess,
    required List<String> groupAllowlist,
  }) {
    final groupJid = message.groupJid;
    if (groupJid == null) {
      if (dmAccess == null || dmAccess.isAllowed(message.senderJid)) {
        return ChannelInboundDecision.admitted;
      }
      return dmAccess.mode == DmAccessMode.pairing
          ? ChannelInboundDecision.dmPairingRequired
          : ChannelInboundDecision.dmDenied;
    }

    switch (groupAccess) {
      case GroupAccessMode.disabled:
        return ChannelInboundDecision.groupAccessDisabled;
      case GroupAccessMode.allowlist:
        if (!groupAllowlist.contains(groupJid)) return ChannelInboundDecision.groupNotAllowlisted;
      case GroupAccessMode.open:
        break;
    }

    if (mentionGating != null && !mentionGating.shouldProcess(message)) {
      return ChannelInboundDecision.mentionRequired;
    }

    return ChannelInboundDecision.admitted;
  }
}
