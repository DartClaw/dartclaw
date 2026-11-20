import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelFeedbackStrategy, FeedbackContext, TurnProgressSnapshot;
import 'package:logging/logging.dart';

import 'slack_markdown.dart';
import 'slack_web_api_client.dart';

const _maxAppendChars = 12000;
const _minWriteInterval = Duration(seconds: 1);

/// Progress feedback for one Slack turn: the thread's agent session is
/// `processing` while it runs, and the reply streams into the thread as the
/// agent writes it.
///
/// One instance serves one turn. The reply ends as exactly one message holding
/// the turn's reply, or the strategy reports it did not deliver and the queue
/// posts the reply instead:
///
/// - Text is released only through the last whitespace of the redacted
///   accumulation, so a secret split across two deltas is never sent in part.
/// - Appends are at most 12,000 characters and at least a second apart.
/// - The stream carries every text delta, including text written before a tool
///   call, so at completion the stream message is edited into the redacted,
///   Slack-formatted reply when it differs from it.
/// - A failed stream call stops the stream and has the message edited into the
///   complete reply; when that edit fails too, [onTurnCompleted] returns `false`.
/// - A reply that does not fit one `chat.update` (4,000 characters, so also any
///   stream Slack cut off at its 12,000-character total) is split: the first
///   chunk is written over the stream message and the rest are posted.
///
/// The session is set `active` when the turn completes, fails or is cancelled,
/// because Slack no longer ends `processing` when the reply posts. With
/// streaming off or without a thread no stream call is made. A status call that
/// fails is logged and never delays or fails the turn.
class SlackFeedbackStrategy implements ChannelFeedbackStrategy {
  static final _log = Logger('SlackFeedbackStrategy');

  final SlackWebApiClient _api;
  final String _channel;
  final String? _threadTs;
  final String? _recipientTeamId;
  final String? _recipientUserId;
  final bool _canStream;
  final String Function(String) _redact;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  final StringBuffer _raw = StringBuffer();
  final StringBuffer _sent = StringBuffer();
  String? _streamTs;
  var _sentChars = 0;
  var _broken = false;
  var _pumping = false;
  Future<void> _pump = Future.value();
  DateTime? _lastWriteAt;

  /// Creates the strategy for the thread [threadTs] of [channel].
  ///
  /// A conversation in a channel passes [recipientTeamId] and [recipientUserId],
  /// which Slack requires to stream there. A null [threadTs] (a slash command)
  /// means there is nothing to stream into or show a status on. [redact] masks
  /// secrets in the accumulated text; [now] and [delay] stand in for the clock.
  new({
    required SlackWebApiClient api,
    required String channel,
    required String? threadTs,
    required bool streaming,
    String? recipientTeamId,
    String? recipientUserId,
    String Function(String)? redact,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _api = api,
       _channel = channel,
       _threadTs = threadTs,
       _recipientTeamId = recipientTeamId,
       _recipientUserId = recipientUserId,
       _canStream = streaming && threadTs != null,
       _redact = redact ?? ((text) => text),
       _now = now ?? DateTime.now,
       _delay = delay ?? Future.delayed;

  @override
  Future<void> onTurnStarted({required FeedbackContext context, TurnProgressSnapshot? snapshot}) =>
      _setStatus(SlackSessionStatus.processing);

  @override
  Future<void> onTextDelta({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String text,
  }) async {
    if (!_canStream || _broken) return;
    _raw.write(text);
    if (!_pumping) _pump = _runPump();
  }

  @override
  Future<void> onToolUse({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String toolName,
  }) async {}

  @override
  Future<void> onToolResult({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String toolName,
    required bool isError,
  }) async {}

  @override
  Future<void> onStatusTick({required FeedbackContext context, required TurnProgressSnapshot snapshot}) async {}

  /// Ends the stream and sets the session active; the partial stream message stays.
  ///
  /// Called when the turn failed, so there is no reply to reconcile.
  Future<void> onTurnFailed() async {
    await _pump;
    final ts = _streamTs;
    if (ts != null) await _stop(ts, tail: null);
    await _setStatus(SlackSessionStatus.active);
  }

  /// Delivers the reply as the stream message and returns whether exactly one
  /// message now holds all of it.
  ///
  /// `false` means nothing delivered the reply (streaming off, no text deltas, a
  /// start failure, or an edit that failed) and the caller must post it.
  @override
  Future<bool> onTurnCompleted({required FeedbackContext context, required String responseText}) async {
    await _pump;
    try {
      final ts = _streamTs;
      if (ts == null) return false;
      return await _finish(ts, responseText);
    } finally {
      await _setStatus(SlackSessionStatus.active);
    }
  }

  Future<bool> _finish(String ts, String responseText) async {
    final tail = _broken ? null : _unreleased();
    await _stop(ts, tail: tail);

    final reply = _redact(responseText);
    final formatted = slackReplyText(reply);
    if (formatted.isEmpty) return true;
    // A stream may hold more than one `chat.update` accepts, so an equal one is kept as it is.
    if (!_broken && _sent.toString().trim() == formatted.trim()) return true;

    final chunks = slackReplyChunks(reply);
    if (!await _edit(ts, chunks.first)) return false;
    for (final chunk in chunks.skip(1)) {
      try {
        await _api.postMessage(channel: _channel, text: chunk, threadTs: _threadTs);
      } on SlackApiException catch (error) {
        _log.warning('Dropping a Slack reply chunk for $_channel: $error');
      }
    }
    return true;
  }

  /// Sends the released text, one append at a time, until nothing releasable is left.
  Future<void> _runPump() async {
    _pumping = true;
    try {
      while (!_broken && _nextChunk() != null) {
        final last = _lastWriteAt;
        if (last != null) {
          final wait = _minWriteInterval - _now().difference(last);
          if (wait > Duration.zero) await _delay(wait);
        }
        // More text may have arrived while waiting; the chunk is cut after the wait.
        final chunk = _nextChunk();
        if (chunk == null) return;
        await _write(chunk);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _write(({String text, int chars}) chunk) async {
    final ts = _streamTs;
    try {
      if (ts == null) {
        _streamTs = await _api.startStream(
          channel: _channel,
          threadTs: _threadTs!,
          recipientTeamId: _recipientTeamId,
          recipientUserId: _recipientUserId,
          markdownText: chunk.text,
        );
      } else {
        await _api.appendStream(channel: _channel, ts: ts, markdownText: chunk.text);
      }
      _sent.write(chunk.text);
      _sentChars += chunk.chars;
    } on SlackApiException catch (error) {
      _broken = true;
      _log.warning(
        ts == null
            ? 'Could not start a Slack stream in $_channel; the reply will be posted instead: $error'
            : 'A Slack stream in $_channel failed midway; the reply will replace it: $error',
      );
    } finally {
      _lastWriteAt = _now();
    }
  }

  /// The redacted accumulation with leading whitespace dropped, as Slack formats a reply.
  String _accumulated() => _redact(_raw.toString()).trimLeft();

  /// The next append: released text up to the last whitespace, escaped, cut to Slack's bound.
  ({String text, int chars})? _nextChunk() {
    final accumulated = _accumulated();
    var end = accumulated.length;
    while (end > _sentChars && !_isWhitespace(accumulated.codeUnitAt(end - 1))) {
      end--;
    }
    if (end <= _sentChars) return null;

    final escaped = StringBuffer();
    var chars = 0;
    while (_sentChars + chars < end) {
      final unit = escapeSlackMarkdown(accumulated[_sentChars + chars]);
      if (escaped.length + unit.length > _maxAppendChars) break;
      escaped.write(unit);
      chars++;
    }
    // A cut between the two halves of a surrogate pair would send half a character.
    if (chars > 0 && _isHighSurrogate(accumulated.codeUnitAt(_sentChars + chars - 1))) {
      final text = escaped.toString();
      return (text: text.substring(0, text.length - 1), chars: chars - 1);
    }
    return chars == 0 ? null : (text: escaped.toString(), chars: chars);
  }

  /// What the accumulation holds beyond the released text: the last word, with no whitespace after it yet.
  String? _unreleased() {
    final accumulated = _accumulated();
    if (accumulated.length <= _sentChars) return null;
    final escaped = escapeSlackMarkdown(accumulated.substring(_sentChars));
    // Past one append the rest is left to the reconciling edit rather than split here.
    return escaped.length > _maxAppendChars ? null : escaped;
  }

  Future<void> _stop(String ts, {required String? tail}) async {
    try {
      await _api.stopStream(channel: _channel, ts: ts, markdownText: tail);
      if (tail != null) _sent.write(tail);
    } on SlackApiException catch (error) {
      _broken = true;
      _log.warning('Could not end the Slack stream in $_channel: $error');
    }
  }

  Future<bool> _edit(String ts, String text) async {
    try {
      await _api.updateMessage(channel: _channel, ts: ts, text: text);
      return true;
    } on SlackApiException catch (error) {
      _log.warning('Could not edit the Slack stream message in $_channel into the reply: $error');
      return false;
    }
  }

  Future<void> _setStatus(SlackSessionStatus status) async {
    final threadTs = _threadTs;
    if (threadTs == null) return;
    try {
      await _api.setSessionStatus(channel: _channel, threadTs: threadTs, status: status);
    } on SlackApiException catch (error) {
      _log.warning('Could not set the Slack agent session status to ${status.name} in $_channel: $error');
    }
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 || (codeUnit >= 0x09 && codeUnit <= 0x0d) || codeUnit == 0xa0;

  static bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;
}
