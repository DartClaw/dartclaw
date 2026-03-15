import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../api/sse_broadcast.dart';

/// How a scheduled job's output is delivered after execution.
enum DeliveryMode { announce, webhook, none }

final _legacyLog = Logger('Delivery');

/// Delivers scheduled job results to SSE clients, channels, or webhooks.
class DeliveryService {
  static final _log = Logger('DeliveryService');

  final ChannelManager _channelManager;
  final SseBroadcast _sseBroadcast;
  final SessionService _sessions;
  final HttpClient Function() _httpClientFactory;

  DeliveryService({
    required ChannelManager channelManager,
    required SseBroadcast sseBroadcast,
    required SessionService sessions,
    HttpClient Function()? httpClientFactory,
  }) : _channelManager = channelManager,
       _sseBroadcast = sseBroadcast,
       _sessions = sessions,
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
    var delivered = 0;
    var missingChannels = 0;
    var failed = 0;

    for (final target in targets) {
      final channel = channelsByType[target.$1];
      if (channel == null) {
        missingChannels += 1;
        _log.warning('Job $jobId: no registered channel found for ${target.$1.name}');
        continue;
      }

      try {
        await channel.sendMessage(target.$2, ChannelResponse(text: result));
        delivered += 1;
      } catch (error, stackTrace) {
        failed += 1;
        _log.warning(
          'Job $jobId: failed to announce to ${channel.type.name} recipient ${target.$2}',
          error,
          stackTrace,
        );
      }
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

  Set<(ChannelType, String)> _resolveDmTargets(Iterable<Session> sessions) {
    final targets = <(ChannelType, String)>{};

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
        targets.add((channelType, dmTarget.peerId));
        continue;
      }

      for (final channel in _channelManager.channels) {
        if (channel.ownsJid(dmTarget.peerId)) {
          targets.add((channel.type, dmTarget.peerId));
        }
      }
    }

    return targets;
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
    required HttpClient Function() httpClientFactory,
  }) async {
    final client = httpClientFactory();
    try {
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({'job_id': jobId, 'result': result, 'timestamp': DateTime.now().toUtc().toIso8601String()}),
      );
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _log.info('Job $jobId: webhook delivered to $url (${response.statusCode})');
      } else {
        _log.severe('Job $jobId: webhook to $url returned ${response.statusCode}');
      }
      await response.drain<void>();
    } catch (error) {
      _log.severe('Job $jobId: webhook delivery to $url failed: $error');
    } finally {
      client.close();
    }
  }
}

/// Delivers job results according to the delivery mode.
@Deprecated('Use DeliveryService.deliver instead.')
Future<void> deliverResult({
  required DeliveryMode mode,
  required String jobId,
  required String result,
  String? webhookUrl,
  DeliveryService? deliveryService,
}) async {
  if (deliveryService != null) {
    await deliveryService.deliver(mode: mode, jobId: jobId, result: result, webhookUrl: webhookUrl);
    return;
  }

  switch (mode) {
    case DeliveryMode.none:
      return;
    case DeliveryMode.announce:
      _legacyLog.info('Job $jobId result ready for channel delivery (announce stub): ${result.length} chars');
      return;
    case DeliveryMode.webhook:
      if (webhookUrl == null || webhookUrl.isEmpty) {
        _legacyLog.severe('Job $jobId: webhook delivery configured but no webhook_url');
        return;
      }
      await DeliveryService._postWebhook(
        jobId: jobId,
        result: result,
        url: webhookUrl,
        httpClientFactory: HttpClient.new,
      );
  }
}
