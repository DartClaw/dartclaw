import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

import '../restart_service.dart';
import 'allowlist_validator.dart';

sealed class ChannelAccessResult {
  const new();
}

final class ChannelAccessApplied extends ChannelAccessResult {
  final Map<String, Object?> body;

  const new(this.body);
}

final class ChannelAccessRefused extends ChannelAccessResult {
  final int status;
  final String code;
  final String message;

  const new(this.status, this.code, this.message);
}

final class ChannelAccessService {
  new({
    required this.writer,
    required this.dataDir,
    this.whatsAppChannel,
    this.signalChannel,
    this.googleChatChannel,
    this.eventBus,
  });

  final ConfigWriter writer;
  final String dataDir;
  final WhatsAppChannel? whatsAppChannel;
  final SignalChannel? signalChannel;
  final GoogleChatChannel? googleChatChannel;
  final EventBus? eventBus;

  DmAccessController? controllerFor(String type) => switch (type) {
    'whatsapp' => whatsAppChannel?.dmAccess,
    'signal' => signalChannel?.dmAccess,
    'google_chat' => googleChatChannel?.dmAccess,
    _ => null,
  };

  bool supportsGroupAccess(String type) => switch (type) {
    'whatsapp' => whatsAppChannel != null,
    'signal' => signalChannel != null,
    'google_chat' => true,
    _ => false,
  };

  Future<ChannelAccessResult> readAllowlist(String type, String list) async {
    if (list == 'dm') {
      final controller = controllerFor(type);
      if (controller != null) return ChannelAccessApplied({'allowlist': controller.allowlist.toList()});
      if (type == 'google_chat') {
        return ChannelAccessApplied({'allowlist': await writer.readChannelAllowlist(type, 'dm_allowlist')});
      }
      return ChannelAccessRefused(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    if (!supportsGroupAccess(type)) {
      return ChannelAccessRefused(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    return ChannelAccessApplied({'allowlist': await writer.readChannelAllowlist(type, 'group_allowlist')});
  }

  Future<ChannelAccessResult> addAllowlist(String type, String list, Object? entryValue) =>
      _mutateAllowlist(type, list, entryValue, add: true);

  Future<ChannelAccessResult> removeAllowlist(String type, String list, Object? entryValue) =>
      _mutateAllowlist(type, list, entryValue, add: false);

  Future<ChannelAccessResult> _mutateAllowlist(
    String type,
    String list,
    Object? entryValue, {
    required bool add,
  }) async {
    final entry = entryValue;
    if (entry is! String || entry.isEmpty) {
      return const ChannelAccessRefused(400, 'INVALID_INPUT', '"entry" is required and must be a non-empty string');
    }
    final isDm = list == 'dm';
    final controller = isDm ? controllerFor(type) : null;
    if (isDm ? controller == null && type != 'google_chat' : !supportsGroupAccess(type)) {
      return ChannelAccessRefused(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    }
    var stored = entry;
    if (add && isDm) {
      final validationError = validateAllowlistEntry(type, entry);
      if (validationError != null) return ChannelAccessRefused(400, 'INVALID_INPUT', validationError);
      stored = canonicalAllowlistEntry(type, entry);
    }
    final key = isDm ? 'dm_allowlist' : 'group_allowlist';
    final current = controller?.allowlist.toList() ?? await writer.readChannelAllowlist(type, key);
    final contains = current.contains(stored);
    final listLabel = isDm ? 'allowlist' : 'group allowlist';
    if (add == contains) {
      final message = add ? 'Entry "$entry" already in $listLabel' : 'Entry "$entry" not in $listLabel';
      return ChannelAccessRefused(add ? 409 : 404, add ? 'CONFLICT' : 'NOT_FOUND', message);
    }
    final updated = add ? [...current, stored] : current.where((value) => value != stored).toList();
    final failure = await _write(() => writer.writeChannelAllowlist(type, key, updated));
    if (failure != null) return failure;
    if (list == 'dm') {
      add ? controller?.addToAllowlist(stored) : controller?.removeFromAllowlist(stored);
    } else {
      final field = 'channels.$type.group_allowlist';
      writeRestartPending(dataDir, [field]);
      if (add) {
        eventBus?.fire(
          ConfigChangedEvent(
            changedKeys: [field],
            oldValues: {field: current},
            newValues: {field: updated},
            requiresRestart: true,
            timestamp: DateTime.now(),
          ),
        );
      }
    }
    return ChannelAccessApplied({add ? 'added' : 'removed': true, 'allowlist': updated});
  }

  ChannelAccessResult readPairings(String type) {
    final controller = controllerFor(type);
    if (controller == null) return ChannelAccessRefused(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    final now = DateTime.now();
    final pending = controller.pendingPairings;
    return ChannelAccessApplied({
      'pending': [
        for (final pairing in pending)
          {
            'code': pairing.code,
            'senderId': pairing.jid,
            'displayName': pairing.displayName,
            'expiresAt': pairing.expiresAt.toUtc().toIso8601String(),
            'remainingSeconds': pairing.expiresAt.difference(now).inSeconds.clamp(0, 1 << 31),
          },
      ],
      'total': pending.length,
    });
  }

  Future<ChannelAccessResult> confirmPairing(String type, Object? codeValue) async {
    final controller = controllerFor(type);
    if (controller == null) return ChannelAccessRefused(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    final code = codeValue;
    if (code is! String || code.isEmpty) return const ChannelAccessRefused(400, 'INVALID_INPUT', '"code" is required');
    final pairing = controller.pendingPairings.where((value) => value.code == code).firstOrNull;
    if (pairing == null) {
      return const ChannelAccessRefused(404, 'NOT_FOUND', 'Pairing code not found or expired');
    }
    final updated = [...controller.allowlist, pairing.jid];
    final failure = await _write(() => writer.writeChannelAllowlist(type, 'dm_allowlist', updated));
    if (failure != null) return failure;
    if (!controller.confirmPairing(code)) {
      return const ChannelAccessRefused(404, 'NOT_FOUND', 'Pairing code not found or expired');
    }
    return ChannelAccessApplied({'confirmed': true, 'senderId': pairing.jid});
  }

  ChannelAccessResult rejectPairing(String type, Object? codeValue) {
    final controller = controllerFor(type);
    if (controller == null) return ChannelAccessRefused(404, 'NOT_FOUND', 'Channel "$type" is not configured');
    final code = codeValue;
    if (code is! String || code.isEmpty) return const ChannelAccessRefused(400, 'INVALID_INPUT', '"code" is required');
    if (!controller.rejectPairing(code)) return const ChannelAccessRefused(404, 'NOT_FOUND', 'Pairing code not found');
    return const ChannelAccessApplied({'rejected': true});
  }

  Future<ChannelAccessRefused?> _write(Future<void> Function() operation) async {
    try {
      await operation();
      return null;
    } on StateError catch (error) {
      return ChannelAccessRefused(500, 'BACKUP_FAILED', error.message);
    } on FileSystemException catch (error) {
      return ChannelAccessRefused(500, 'WRITE_FAILED', 'Config write failed: ${error.message}');
    }
  }
}
