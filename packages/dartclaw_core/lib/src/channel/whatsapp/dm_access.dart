import 'dart:math';

import 'whatsapp_config.dart';

/// A pending pairing code for DM access control.
class PairingCode {
  final String code;
  final String jid;
  final DateTime expiresAt;

  PairingCode({required this.code, required this.jid, required this.expiresAt});

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Controls which senders are allowed to DM the bot.
class DmAccessController {
  static const _maxPending = 3;
  static const _codeLength = 8;
  static const _codeExpiry = Duration(hours: 1);

  final DmAccessMode mode;
  final Set<String> _allowlist;
  final Map<String, PairingCode> _pendingPairings = {};
  final Random _random;

  DmAccessController({required this.mode, Set<String>? allowlist, Random? random})
    : _allowlist = allowlist ?? {},
      _random = random ?? Random.secure();

  Set<String> get allowlist => Set.unmodifiable(_allowlist);
  int get pendingCount => _pendingPairings.length;

  /// Whether the given sender JID is allowed to message the bot.
  bool isAllowed(String senderJid) {
    switch (mode) {
      case DmAccessMode.open:
        return true;
      case DmAccessMode.disabled:
        return false;
      case DmAccessMode.allowlist:
      case DmAccessMode.pairing:
        return _allowlist.contains(senderJid);
    }
  }

  /// Create a pairing code for a new sender.
  ///
  /// Returns null if max pending pairings reached or mode is not `pairing`.
  PairingCode? createPairing(String senderJid) {
    if (mode != DmAccessMode.pairing) return null;

    _evictExpired();
    if (_pendingPairings.length >= _maxPending) return null;

    // Check if already pending for this JID
    final existing = _pendingPairings.values.where((p) => p.jid == senderJid && !p.isExpired).firstOrNull;
    if (existing != null) return existing;

    final code = _generateCode();
    final pairing = PairingCode(code: code, jid: senderJid, expiresAt: DateTime.now().add(_codeExpiry));
    _pendingPairings[code] = pairing;
    return pairing;
  }

  /// Confirm a pairing code. Returns true if valid, adds JID to allowlist.
  bool confirmPairing(String code) {
    _evictExpired();
    final pairing = _pendingPairings.remove(code);
    if (pairing == null || pairing.isExpired) return false;
    _allowlist.add(pairing.jid);
    return true;
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I ambiguity
    return List.generate(_codeLength, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  void _evictExpired() {
    _pendingPairings.removeWhere((_, p) => p.isExpired);
  }
}
