import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../api/sse_broadcast.dart';
import '../memory/daily_log_record.dart';

/// How a scheduled job's output is delivered after execution.
enum DeliveryMode { announce, webhook, none }

/// What one [DeliveryService.deliverMedia] call reached.
typedef MediaDeliveryReport = ({int attempted, List<String> delivered});

/// One DM recipient of an announce or media send, with the channel sessions
/// that resolved to it.
typedef _DmTarget = ({ChannelType channelType, String peerId, Set<String> sessionIds});

/// Delivers scheduled job results to SSE clients, channels, or webhooks.
class DeliveryService {
  static final _log = Logger('DeliveryService');

  final ChannelManager _channelManager;
  final SseBroadcast _sseBroadcast;
  final SessionService _sessions;
  final MessageService? _messages;
  final MemoryFileService? _memoryFile;
  final MessageRedactor _redactor;
  final Future<void> Function(String sessionId)? _resetSessionContinuity;
  final HttpClientFactory _httpClientFactory;

  new({
    required ChannelManager channelManager,
    required SseBroadcast sseBroadcast,
    required SessionService sessions,
    MessageService? messages,
    MemoryFileService? memoryFile,
    MessageRedactor? redactor,
    Future<void> Function(String sessionId)? resetSessionContinuity,
    HttpClientFactory? httpClientFactory,
  }) : _channelManager = channelManager,
       _sseBroadcast = sseBroadcast,
       _sessions = sessions,
       _messages = messages,
       _memoryFile = memoryFile,
       _redactor = redactor ?? MessageRedactor(),
       _resetSessionContinuity = resetSessionContinuity,
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  Future<void> deliver({
    required DeliveryMode mode,
    required String jobId,
    required String result,
    String? webhookUrl,
  }) async {
    switch (mode) {
      case DeliveryMode.none:
        return;
      case DeliveryMode.announce:
        await _deliverAnnounce(jobId: jobId, result: result);
        return;
      case DeliveryMode.webhook:
        if (webhookUrl == null || webhookUrl.isEmpty) {
          _log.severe('Job $jobId: webhook delivery configured but no webhook_url');
          return;
        }
        await _postWebhook(jobId: jobId, result: result, url: webhookUrl, httpClientFactory: _httpClientFactory);
        return;
    }
  }

  /// Sends [mediaPath] to every DM target an active channel session resolves to.
  ///
  /// Reuses announce delivery's target resolution rather than taking a
  /// recipient: a caller-supplied destination would turn a file send into an
  /// exfiltration primitive.
  ///
  /// [attempted] counts the resolved DM targets and [delivered] names the ones
  /// the file reached. The two are reported separately because "no owner is
  /// reachable" and "every send failed" are different answers, and collapsing
  /// them tells the caller a delivery failure was an absent recipient.
  ///
  /// [mediaPath] is delivered as given — containment is the caller's to prove
  /// before calling, and this service never resolves or checks a path.
  Future<MediaDeliveryReport> deliverMedia({required String mediaPath, String caption = ''}) async {
    final sessions = await _listChannelSessions('attach_media');
    if (sessions == null) return (attempted: 0, delivered: const <String>[]);

    final channelsByType = _channelsByType();
    final targets = _resolveDmTargets(sessions);
    final delivered = <String>[];
    var attempted = 0;
    for (final target in targets) {
      final channel = channelsByType[target.channelType];
      if (channel == null) {
        _log.warning('attach_media: no registered channel found for ${target.channelType.name}');
        continue;
      }
      attempted += 1;
      try {
        await channel.sendMessage(target.peerId, ChannelResponse(text: caption, mediaAttachments: [mediaPath]));
        delivered.add('${target.channelType.name}:${target.peerId}');
      } catch (error, stackTrace) {
        _log.warning(
          'attach_media: failed to send to ${channel.type.name} recipient ${target.peerId}',
          error,
          stackTrace,
        );
      }
    }
    return (attempted: attempted, delivered: delivered);
  }

  Future<void> _deliverAnnounce({required String jobId, required String result}) async {
    _sseBroadcast.broadcast('announce', {
      'jobId': jobId,
      'result': result,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    final sessions = await _listChannelSessions(jobId);
    if (sessions == null) {
      return;
    }

    final targets = _resolveDmTargets(sessions);
    if (targets.isEmpty) {
      _log.info('Job $jobId: announce broadcast sent to SSE; no active DM targets found');
      return;
    }

    final channelsByType = _channelsByType();
    final reachedSessionIds = <String>{};
    var delivered = 0;
    var missingChannels = 0;
    var failed = 0;

    for (final target in targets) {
      final channel = channelsByType[target.channelType];
      if (channel == null) {
        missingChannels += 1;
        _log.warning('Job $jobId: no registered channel found for ${target.channelType.name}');
        continue;
      }

      try {
        for (final response in channel.formatResponse(result)) {
          await channel.sendMessage(target.peerId, response);
        }
        delivered += 1;
        reachedSessionIds.addAll(target.sessionIds);
      } catch (error, stackTrace) {
        failed += 1;
        _log.warning(
          'Job $jobId: failed to announce to ${channel.type.name} recipient ${target.peerId}',
          error,
          stackTrace,
        );
      }
    }

    if (reachedSessionIds.isNotEmpty) {
      await _recordAnnounce(jobId: jobId, result: result, sessionIds: reachedSessionIds);
    }

    _log.info(
      'Job $jobId: announce broadcast sent to SSE and ${targets.length} DM target(s) '
      '(delivered=$delivered, missingChannels=$missingChannels, failed=$failed)',
    );
  }

  Future<List<Session>?> _listChannelSessions(String jobId) async {
    try {
      return await _sessions.listSessions(type: SessionType.channel);
    } catch (error, stackTrace) {
      _log.warning('Job $jobId: failed to list active channel sessions for announce delivery', error, stackTrace);
      return null;
    }
  }

  /// One entry per recipient — two sessions resolving to the same peer are one
  /// send, and both session ids ride along so the announce reaches each
  /// transcript.
  List<_DmTarget> _resolveDmTargets(Iterable<Session> sessions) {
    final sessionIdsByPeer = <(ChannelType, String), Set<String>>{};

    for (final session in sessions) {
      final channelKey = session.channelKey;
      if (channelKey == null || channelKey.isEmpty) {
        continue;
      }

      final dmTarget = _parseDmTarget(channelKey: channelKey, sessionId: session.id);
      if (dmTarget == null) {
        continue;
      }

      final channelType = dmTarget.channelType;
      if (channelType != null) {
        sessionIdsByPeer.putIfAbsent((channelType, dmTarget.peerId), () => {}).add(session.id);
        continue;
      }

      for (final channel in _channelManager.channels) {
        if (channel.ownsJid(dmTarget.peerId)) {
          sessionIdsByPeer.putIfAbsent((channel.type, dmTarget.peerId), () => {}).add(session.id);
        }
      }
    }

    return [
      for (final entry in sessionIdsByPeer.entries)
        (channelType: entry.key.$1, peerId: entry.key.$2, sessionIds: entry.value),
    ];
  }

  /// Records an announce the owner already read on a channel: one assistant
  /// message per session it reached, that session's provider continuity reset so
  /// the next turn replays the transcript, and one daily-log record for the fire.
  Future<void> _recordAnnounce({required String jobId, required String result, required Set<String> sessionIds}) async {
    final messages = _messages;
    for (final sessionId in sessionIds) {
      if (messages != null) {
        try {
          await messages.insertMessage(
            sessionId: sessionId,
            role: 'assistant',
            content: result,
            metadata: jsonEncode({'jobId': jobId, 'origin': 'announce'}),
          );
        } catch (error, stackTrace) {
          _log.warning('Job $jobId: failed to record announce in session $sessionId', error, stackTrace);
          continue;
        }
      }
      try {
        await _resetSessionContinuity?.call(sessionId);
      } on BusyTurnException {
        // The record stands; the next natural cold start replays it.
        _log.info('Job $jobId: session $sessionId is busy — announce replays at its next cold start');
      } catch (error, stackTrace) {
        _log.warning('Job $jobId: failed to reset continuity for session $sessionId', error, stackTrace);
      }
    }

    final memoryFile = _memoryFile;
    if (memoryFile == null) return;
    try {
      await memoryFile.appendDailyLog(
        buildDailyLogRecord(
          at: DateTime.now(),
          redactor: _redactor,
          title: 'Announce: $jobId',
          userMessage: '(scheduled)',
          toolSummaries: const [],
          result: result,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Job $jobId: failed to append the announce daily-log record', error, stackTrace);
    }
  }

  Map<ChannelType, Channel> _channelsByType() {
    final channels = <ChannelType, Channel>{};
    for (final channel in _channelManager.channels) {
      channels.putIfAbsent(channel.type, () => channel);
    }
    return channels;
  }

  ({ChannelType? channelType, String peerId})? _parseDmTarget({required String channelKey, required String sessionId}) {
    try {
      final sessionKey = SessionKey.parse(channelKey);
      if (sessionKey.scope != 'dm') {
        return null;
      }
      if (sessionKey.identifiers == 'shared' || sessionKey.identifiers.isEmpty) {
        return null;
      }

      final parts = sessionKey.identifiers.split(':');
      if (parts.length != 2) {
        _log.fine('Skipping DM session $sessionId with unsupported identifiers "${sessionKey.identifiers}"');
        return null;
      }

      final peerId = Uri.decodeComponent(parts[1]);
      if (peerId.isEmpty) {
        return null;
      }

      if (parts[0] == 'contact') {
        return (channelType: null, peerId: peerId);
      }

      final channelTypeName = Uri.decodeComponent(parts[0]);
      final channelType = ChannelType.values.asNameMap()[channelTypeName];
      if (channelType == null) {
        _log.warning('Skipping DM session $sessionId with unknown channel type "$channelTypeName"');
        return null;
      }

      return (channelType: channelType, peerId: peerId);
    } on FormatException catch (error, stackTrace) {
      _log.warning('Skipping malformed DM session key "$channelKey"', error, stackTrace);
      return null;
    }
  }

  static Future<void> _postWebhook({
    required String jobId,
    required String result,
    required String url,
    required HttpClientFactory httpClientFactory,
  }) async {
    try {
      final response = await httpRequest(
        Uri.parse(url),
        method: 'POST',
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.toString()},
        body: jsonEncode({'job_id': jobId, 'result': result, 'timestamp': DateTime.now().toUtc().toIso8601String()}),
        connectionTimeout: const Duration(seconds: 10),
        timeout: const Duration(seconds: 10),
        factory: httpClientFactory,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _log.info('Job $jobId: webhook delivered to $url (${response.statusCode})');
      } else {
        _log.severe('Job $jobId: webhook to $url returned ${response.statusCode}');
      }
    } catch (error) {
      _log.severe('Job $jobId: webhook delivery to $url failed: $error');
    }
  }
}
