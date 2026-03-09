import 'dart:async';

import 'package:logging/logging.dart';

import '../channel.dart';
import '../channel_manager.dart';
import '../whatsapp/text_chunking.dart';
import 'signal_cli_manager.dart';
import 'signal_sender_map.dart';
import '../dm_access.dart';
import 'signal_config.dart';
import 'signal_dm_access.dart';

/// Signal channel implementation via signal-cli subprocess.
class SignalChannel extends Channel {
  static final _log = Logger('SignalChannel');

  @override
  final String name = 'signal';
  @override
  final ChannelType type = ChannelType.signal;

  final SignalCliManager sidecar;
  final SignalConfig config;
  final DmAccessController dmAccess;
  final SignalMentionGating mentionGating;
  final ChannelManager? _channelManager;
  final String? _dataDir;
  SignalSenderMap? _senderMap;
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  SignalChannel({
    required this.sidecar,
    required this.config,
    required this.dmAccess,
    required this.mentionGating,
    ChannelManager? channelManager,
    String? dataDir,
  }) : _channelManager = channelManager,
       _dataDir = dataDir;

  @override
  Future<void> connect() async {
    _log.info('Starting Signal channel');
    if (_dataDir != null) {
      final mapPath = '$_dataDir/channels/signal/signal-sender-map.json';
      _senderMap = SignalSenderMap(filePath: mapPath);
      await _senderMap!.load();
    }
    await sidecar.start();
    _eventSub = sidecar.events.listen(_handleEvent);
    _log.info('Signal channel connected');
  }

  @override
  Future<void> sendMessage(String recipientId, ChannelResponse response) async {
    if (!sidecar.isRunning) return;

    if (response.text.isNotEmpty) {
      try {
        await sidecar.sendMessage(recipientId, response.text);
      } catch (e) {
        _log.warning('Failed to send text to $recipientId', e);
        rethrow;
      }
    }
  }

  @override
  bool ownsJid(String jid) {
    // Signal identifiers are either E.164 phone numbers (+...) or ACI UUIDs
    // (sealed-sender). Both lack the '@' present in WhatsApp JIDs.
    if (jid.contains('@')) return false;
    if (jid.startsWith('+')) return true;
    // UUID v4 pattern (signal-cli ACI): 8-4-4-4-12 hex
    return RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(jid);
  }

  @override
  List<ChannelResponse> formatResponse(String text) {
    final chunks = chunkText(text, maxSize: config.maxChunkSize);
    return [for (final chunk in chunks) ChannelResponse(text: chunk)];
  }

  @override
  Future<void> disconnect() async {
    _log.info('Disconnecting Signal channel');
    await _eventSub?.cancel();
    _eventSub = null;
    await sidecar.reset();
    _log.info('Signal channel disconnected');
  }

  /// Handle an inbound SSE event from signal-cli daemon.
  void _handleEvent(Map<String, dynamic> payload) {
    try {
      final message = _parseEnvelope(payload);
      if (message == null) return;

      // DM access control
      if (message.groupJid == null && !dmAccess.isAllowed(message.senderJid)) {
        // Sealed-sender: senderJid may be phone while allowlist holds UUID (or vice versa).
        // Check the alternate UUID form stored in metadata.
        final altId = message.metadata['sourceUuid'] as String?;
        if (altId != null && altId != message.senderJid && dmAccess.isAllowed(altId)) {
          // Resolved via alternate. Normalize: add senderJid so future lookups skip the fallback.
          dmAccess.addToAllowlist(message.senderJid);
          // fall through — message is allowed
        } else {
          if (dmAccess.mode == DmAccessMode.pairing) {
            final displayName = message.metadata['sourceName'] as String?;
            final pairing = dmAccess.createPairing(
              message.senderJid,
              displayName: displayName,
            );
            if (pairing != null) {
              _log.info('Pairing request created for ${message.senderJid}');
            } else {
              _log.warning(
                'Max pending pairings reached — dropping message from ${message.senderJid}',
              );
            }
          } else {
            _log.fine('DM from unapproved sender ${message.senderJid} — dropping');
          }
          return;
        }
      }

      // Group access control
      if (message.groupJid != null) {
        switch (config.groupAccess) {
          case SignalGroupAccessMode.disabled:
            _log.fine('Group message from ${message.groupJid} — group access disabled');
            return;
          case SignalGroupAccessMode.allowlist:
            if (!config.groupAllowlist.contains(message.groupJid)) {
              _log.fine('Group ${message.groupJid} not in allowlist — dropping');
              return;
            }
          case SignalGroupAccessMode.open:
            break;
        }
      }

      // Mention gating (groups only)
      if (!mentionGating.shouldProcess(message)) {
        _log.fine('Group message without mention — ignoring');
        return;
      }

      _channelManager?.handleInboundMessage(message);
    } catch (e, st) {
      _log.warning('Failed to handle Signal event', e, st);
    }
  }

  /// Parse signal-cli envelope.
  ///
  /// Expected format:
  /// ```json
  /// {
  ///   "envelope": {
  ///     "source": "+1234567890",
  ///     "sourceName": "Alice",
  ///     "dataMessage": {
  ///       "message": "Hello",
  ///       "groupInfo": { "groupId": "base64..." }
  ///     }
  ///   }
  /// }
  /// ```
  ChannelMessage? _parseEnvelope(Map<String, dynamic> raw) {
    final envelope = raw['envelope'] as Map<String, dynamic>?;
    if (envelope == null) return null;

    // signal-cli provides multiple sender fields:
    // - 'sourceNumber': E.164 phone (e.g. "+1234567890") — preferred
    // - 'sourceUuid': ACI UUID (e.g. "12bfcd5a-...") — sealed-sender fallback
    // - 'source': may be either phone or UUID depending on signal-cli version
    // Use sender map for UUID->phone normalization when available.
    final sourceNumber = envelope['sourceNumber'] as String?;
    final sourceUuid = envelope['sourceUuid'] as String?;
    final source = _senderMap?.resolve(
          sourceNumber: sourceNumber,
          sourceUuid: sourceUuid,
        ) ??
        (sourceNumber?.isNotEmpty == true
            ? sourceNumber
            : (envelope['source'] as String?)?.isNotEmpty == true
                ? envelope['source'] as String
                : sourceUuid);
    if (source == null || source.isEmpty) return null;

    final dataMessage = envelope['dataMessage'] as Map<String, dynamic>?;
    if (dataMessage == null) return null;

    final text = dataMessage['message'] as String?;
    if (text == null || text.isEmpty) return null;

    // Group detection
    String? groupId;
    final groupInfo = dataMessage['groupInfo'] as Map<String, dynamic>?;
    if (groupInfo != null) {
      groupId = groupInfo['groupId'] as String?;
    }

    return ChannelMessage(
      channelType: ChannelType.signal,
      senderJid: source,
      groupJid: groupId,
      text: text,
      mentionedJids: const [],
      metadata: {
        if (envelope['sourceName'] != null) 'sourceName': envelope['sourceName'],
        if (envelope['sourceUuid'] != null) 'sourceUuid': envelope['sourceUuid'],
      },
    );
  }
}
