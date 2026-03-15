import 'dart:math';

/// Access control mode for direct messages — shared across all channels.
enum DmAccessMode {
  /// Unknown senders must be explicitly paired before access is granted.
  pairing,

  /// Only senders in the allowlist may interact with the runtime.
  allowlist,

  /// Any sender may interact with the runtime.
  open,

  /// Direct messages are disabled entirely.
  disabled,
}

/// A pending pairing code for DM access control.
class PairingCode {
  /// Human-entered pairing code shown to the operator.
  final String code;

  /// Sender identifier requesting approval.
  final String jid;

  /// Absolute expiry timestamp after which the code is invalid.
  final DateTime expiresAt;

  /// Optional display name captured from the channel event.
  final String? displayName;

  /// Creates a pending pairing record.
  PairingCode({required this.code, required this.jid, required this.expiresAt, this.displayName});

  /// Whether this pairing has expired and should be evicted.
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Controls which senders are allowed to DM the bot.
class DmAccessController {
  static const _maxPending = 3;
  static const _codeLength = 8;
  static const _codeExpiry = Duration(hours: 1);

  /// Access policy applied to inbound direct messages.
  final DmAccessMode mode;
  final Set<String> _allowlist;
  final Map<String, PairingCode> _pendingPairings = {};
  final Random _random;

  /// Creates a DM access controller with an optional initial allowlist.
  DmAccessController({required this.mode, Set<String>? allowlist, Random? random})
    : _allowlist = allowlist ?? {},
      _random = random ?? Random.secure();

  /// Immutable snapshot of approved sender identifiers.
  Set<String> get allowlist => Set.unmodifiable(_allowlist);

  /// Number of non-expired pending pairing requests currently tracked.
  int get pendingCount => _pendingPairings.length;

  /// Returns non-expired pending pairings (evicts expired first).
  List<PairingCode> get pendingPairings {
    _evictExpired();
    return _pendingPairings.values.where((p) => !p.isExpired).toList();
  }

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
  PairingCode? createPairing(String senderJid, {String? displayName}) {
    if (mode != DmAccessMode.pairing) return null;

    _evictExpired();
    if (_pendingPairings.length >= _maxPending) return null;

    // Check if already pending for this JID
    final existing = _pendingPairings.values.where((p) => p.jid == senderJid && !p.isExpired).firstOrNull;
    if (existing != null) return existing;

    final code = _generateCode();
    final pairing = PairingCode(
      code: code,
      jid: senderJid,
      expiresAt: DateTime.now().add(_codeExpiry),
      displayName: displayName,
    );
    _pendingPairings[code] = pairing;
    return pairing;
  }

  /// Add an entry to the allowlist.
  void addToAllowlist(String entry) => _allowlist.add(entry);

  /// Remove an entry from the allowlist. Returns true if the entry was present.
  bool removeFromAllowlist(String entry) => _allowlist.remove(entry);

  /// Confirm a pairing code. Returns true if valid, adds JID to allowlist.
  bool confirmPairing(String code) {
    _evictExpired();
    final pairing = _pendingPairings.remove(code);
    if (pairing == null || pairing.isExpired) return false;
    _allowlist.add(pairing.jid);
    return true;
  }

  /// Reject a pairing code. Returns true if found, removes without adding to allowlist.
  bool rejectPairing(String code) {
    return _pendingPairings.remove(code) != null;
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I ambiguity
    return List.generate(_codeLength, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  void _evictExpired() {
    _pendingPairings.removeWhere((_, p) => p.isExpired);
  }
}
