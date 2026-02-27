/// Deterministic session key format: `agent:<agentId>:<scope>:<identifiers>`.
///
/// Identifiers are URL-encoded to avoid delimiter collision with `:`.
class SessionKey {
  final String agentId;
  final String scope;
  final String identifiers;

  const SessionKey({
    required this.agentId,
    required this.scope,
    this.identifiers = '',
  });

  /// Generates key string: `agent:<agentId>:<scope>:<url-encoded identifiers>`.
  @override
  String toString() =>
      'agent:$agentId:$scope:${Uri.encodeComponent(identifiers)}';

  /// Parses a key string back into a [SessionKey].
  factory SessionKey.parse(String key) {
    final parts = key.split(':');
    if (parts.length < 4 || parts[0] != 'agent') {
      throw FormatException('Invalid session key format: $key');
    }
    return SessionKey(
      agentId: parts[1],
      scope: parts[2],
      identifiers: Uri.decodeComponent(parts.sublist(3).join(':')),
    );
  }

  /// Primary web session key.
  static String webSession({String agentId = 'main'}) =>
      SessionKey(agentId: agentId, scope: 'main').toString();

  /// Per-peer session key (e.g. WhatsApp DM).
  static String peerSession({required String agentId, required String peerId}) =>
      SessionKey(agentId: agentId, scope: 'per-peer', identifiers: peerId).toString();
}
