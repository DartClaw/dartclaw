/// Deterministic session key format: `agent:<agentId>:<scope>:<identifiers>`.
///
/// Factory methods pre-encode individual identifier components.
/// The [identifiers] field is stored as-is (already encoded by factories).
class SessionKey {
  final String agentId;
  final String scope;
  final String identifiers;

  const SessionKey({
    required this.agentId,
    required this.scope,
    this.identifiers = '',
  });

  /// Generates key string: `agent:<agentId>:<scope>:<identifiers>`.
  /// Identifiers are assumed to be pre-encoded by factory methods.
  @override
  String toString() => 'agent:$agentId:$scope:$identifiers';

  /// Parses a key string back into a [SessionKey].
  factory SessionKey.parse(String key) {
    final parts = key.split(':');
    if (parts.length < 4 || parts[0] != 'agent') {
      throw FormatException('Invalid session key format: $key');
    }
    return SessionKey(
      agentId: parts[1],
      scope: parts[2],
      identifiers: parts.sublist(3).join(':'),
    );
  }

  /// Primary web session key.
  static String webSession({String agentId = 'main'}) =>
      SessionKey(agentId: agentId, scope: 'main').toString();

  /// Per-peer session key (e.g. WhatsApp DM).
  static String peerSession({required String agentId, required String peerId}) =>
      SessionKey(
        agentId: agentId,
        scope: 'per-peer',
        identifiers: Uri.encodeComponent(peerId),
      ).toString();

  /// Per-channel-peer session key (e.g., WhatsApp group messages).
  static String channelPeerSession({
    String agentId = 'main',
    required String channelType,
    required String channelId,
    required String peerId,
  }) =>
      SessionKey(
        agentId: agentId,
        scope: 'per-channel-peer',
        identifiers:
            '${Uri.encodeComponent(channelType)}:${Uri.encodeComponent(channelId)}:${Uri.encodeComponent(peerId)}',
      ).toString();

  /// Per-account-channel-peer session key.
  static String accountChannelPeerSession({
    String agentId = 'main',
    required String accountId,
    required String channelType,
    required String channelId,
    required String peerId,
  }) =>
      SessionKey(
        agentId: agentId,
        scope: 'per-account-channel-peer',
        identifiers:
            '${Uri.encodeComponent(accountId)}:${Uri.encodeComponent(channelType)}:${Uri.encodeComponent(channelId)}:${Uri.encodeComponent(peerId)}',
      ).toString();

  /// Cron session key.
  static String cronSession({String agentId = 'main', required String jobId}) =>
      SessionKey(
        agentId: agentId,
        scope: 'cron',
        identifiers: Uri.encodeComponent(jobId),
      ).toString();
}
