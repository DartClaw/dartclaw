import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'markdown_formatter.dart';
import 'signal_config.dart';
import 'signal_cli_manager.dart';
import 'signal_dm_access.dart';
import 'signal_sender_map.dart';

bool _isDirectRecipient(String recipientId) {
  if (recipientId.contains('@')) return false;
  return isValidSignalE164(recipientId) || isValidSignalUuid(recipientId);
}

/// Signal channel implementation via signal-cli subprocess.
class SignalChannel extends Channel {
  static final _log = Logger('SignalChannel');
  static const _typingRefreshInterval = Duration(seconds: 10);

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
  final Map<String, int> _typingLeases = {};
  final Map<String, Timer> _typingRefreshTimers = {};
  final Map<String, Future<void>> _typingUpdates = {};
  final Set<String> _typingActive = {};
  final Set<String> _typingStartRetryUsed = {};
  bool _disconnecting = false;

  new({
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
    _disconnecting = false;
    _eventSub = sidecar.events.listen(_handleEvent);
    switch (await sidecar.registrationState()) {
      case SignalRegistrationState.registered:
        _log.info('Signal channel started with a registered account');
      case SignalRegistrationState.unregistered:
        _log.warning(
          'Signal channel started, but no account is registered; inbound messages are unavailable until pairing completes',
        );
      case SignalRegistrationState.unknown:
        _log.warning('Signal channel started, but account registration could not be confirmed');
    }
  }

  @override
  Future<void> sendMessage(String recipientId, ChannelResponse response) async {
    if (!sidecar.isRunning) return;

    if (response.text.isNotEmpty) {
      try {
        final textStyles = switch (response.metadata[signalTextStylesMetadataKey]) {
          final List<dynamic> values => values.whereType<String>().toList(),
          _ => const <String>[],
        };
        await sidecar.sendMessage(
          recipientId,
          response.text,
          isGroup: !_isDirectRecipient(recipientId),
          textStyles: textStyles,
        );
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
    return _isDirectRecipient(jid);
  }

  @override
  Future<void> startTyping(String recipientJid) async {
    if (_disconnecting || !sidecar.isRunning) return;

    final activeLeases = _typingLeases[recipientJid] ?? 0;
    _typingLeases[recipientJid] = activeLeases + 1;

    final isGroup = !_isDirectRecipient(recipientJid);
    if (activeLeases == 0) {
      _typingStartRetryUsed.remove(recipientJid);
      _typingRefreshTimers[recipientJid] = Timer.periodic(_typingRefreshInterval, (_) {
        unawaited(
          _queueTypingUpdate(recipientJid, isGroup: isGroup, isTyping: true).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            _log.warning('Failed to refresh Signal typing for $recipientJid', error, stackTrace);
          }),
        );
      });
      await _queueTypingUpdate(recipientJid, isGroup: isGroup, isTyping: true);
      return;
    }

    final pending = _typingUpdates[recipientJid];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    if (_typingActive.contains(recipientJid) ||
        _disconnecting ||
        (_typingLeases[recipientJid] ?? 0) == 0 ||
        !_typingStartRetryUsed.add(recipientJid)) {
      return;
    }
    await _queueTypingUpdate(recipientJid, isGroup: isGroup, isTyping: true);
  }

  @override
  Future<void> stopTyping(String recipientJid) async {
    final activeLeases = _typingLeases[recipientJid] ?? 0;
    if (activeLeases > 1) {
      _typingLeases[recipientJid] = activeLeases - 1;
      return;
    }

    _typingLeases.remove(recipientJid);
    _typingStartRetryUsed.remove(recipientJid);
    _typingRefreshTimers.remove(recipientJid)?.cancel();
    if (!sidecar.isRunning || activeLeases == 0) return;

    await _queueTypingUpdate(recipientJid, isGroup: !_isDirectRecipient(recipientJid), isTyping: false);
  }

  @override
  List<ChannelResponse> formatResponse(String text) => formatSignalMarkdown(text, maxSize: config.maxChunkSize);

  @override
  Future<void> disconnect() async {
    _log.info('Disconnecting Signal channel');
    _disconnecting = true;
    for (final timer in _typingRefreshTimers.values) {
      timer.cancel();
    }
    _typingRefreshTimers.clear();
    final activeRecipients = {..._typingLeases.keys, ..._typingActive};
    _typingLeases.clear();
    if (sidecar.isRunning) {
      await Future.wait(
        activeRecipients.map(
          (recipientJid) =>
              _queueTypingUpdate(recipientJid, isGroup: !_isDirectRecipient(recipientJid), isTyping: false).catchError((
                Object error,
                StackTrace stackTrace,
              ) {
                _log.warning('Failed to stop Signal typing during disconnect for $recipientJid', error, stackTrace);
              }),
        ),
      );
    }
    await Future.wait(
      _typingUpdates.values.toList().map(
        (update) => update.catchError((Object error, StackTrace stackTrace) {
          _log.fine('Signal typing update ended during disconnect: $error');
        }),
      ),
    );
    _typingUpdates.clear();
    _typingActive.clear();
    _typingStartRetryUsed.clear();
    await _eventSub?.cancel();
    _eventSub = null;
    await sidecar.reset();
    _log.info('Signal channel disconnected');
  }

  Future<void> _queueTypingUpdate(String recipientJid, {required bool isGroup, required bool isTyping}) {
    final previous = _typingUpdates[recipientJid] ?? Future<void>.value();
    final update = previous.then<void>((_) {}, onError: (Object _, StackTrace _) {}).then((_) async {
      await sidecar.sendTyping(recipientJid, isGroup: isGroup, isTyping: isTyping);
      if (isTyping) {
        _typingActive.add(recipientJid);
      } else {
        _typingActive.remove(recipientJid);
      }
    });
    late final Future<void> tracked;
    tracked = update.whenComplete(() {
      if (identical(_typingUpdates[recipientJid], tracked)) {
        _typingUpdates.remove(recipientJid);
      }
    });
    _typingUpdates[recipientJid] = tracked;
    return tracked;
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
            final pairing = dmAccess.createPairing(message.senderJid, displayName: displayName);
            if (pairing != null) {
              _log.info('Pairing request created for ${message.senderJid}');
            } else {
              _log.warning('Max pending pairings reached — dropping message from ${message.senderJid}');
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
            if (!config.groupIds.contains(message.groupJid)) {
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
    final source =
        _senderMap?.resolve(sourceNumber: sourceNumber, sourceUuid: sourceUuid) ??
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
