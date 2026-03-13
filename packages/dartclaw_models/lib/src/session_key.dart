/// Deterministic session key format: `agent:<agentId>:<scope>:<identifiers>`.
///
/// Factory methods pre-encode individual identifier components.
/// The [identifiers] field is stored as-is (already encoded by factories).
class SessionKey {
  final String agentId;
  final String scope;
  final String identifiers;

  const SessionKey({required this.agentId, required this.scope, this.identifiers = ''});

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
    return SessionKey(agentId: parts[1], scope: parts[2], identifiers: parts.sublist(3).join(':'));
  }

  /// Primary web session key.
  static String webSession({String agentId = 'main'}) => SessionKey(agentId: agentId, scope: 'web').toString();

  /// Shared DM session — all DM contacts share one session.
  static String dmShared({String agentId = 'main'}) =>
      SessionKey(agentId: agentId, scope: 'dm', identifiers: 'shared').toString();

  /// Per-contact DM session — one session per contact across all channels.
  static String dmPerContact({String agentId = 'main', required String peerId}) {
    if (peerId.isEmpty) throw ArgumentError('peerId must not be empty');
    return SessionKey(agentId: agentId, scope: 'dm', identifiers: 'contact:${Uri.encodeComponent(peerId)}').toString();
  }

  /// Per-channel-contact DM session — one session per contact per channel type.
  static String dmPerChannelContact({String agentId = 'main', required String channelType, required String peerId}) {
    if (peerId.isEmpty) throw ArgumentError('peerId must not be empty');
    return SessionKey(
      agentId: agentId,
      scope: 'dm',
      identifiers: '${Uri.encodeComponent(channelType)}:${Uri.encodeComponent(peerId)}',
    ).toString();
  }

  /// Shared group session — one session per group.
  static String groupShared({String agentId = 'main', required String channelType, required String groupId}) {
    if (groupId.isEmpty) throw ArgumentError('groupId must not be empty');
    return SessionKey(
      agentId: agentId,
      scope: 'group',
      identifiers: '${Uri.encodeComponent(channelType)}:${Uri.encodeComponent(groupId)}',
    ).toString();
  }

  /// Per-member group session — one session per member in a group.
  static String groupPerMember({
    String agentId = 'main',
    required String channelType,
    required String groupId,
    required String peerId,
  }) {
    if (groupId.isEmpty) throw ArgumentError('groupId must not be empty');
    if (peerId.isEmpty) throw ArgumentError('peerId must not be empty');
    return SessionKey(
      agentId: agentId,
      scope: 'group',
      identifiers: '${Uri.encodeComponent(channelType)}:${Uri.encodeComponent(groupId)}:${Uri.encodeComponent(peerId)}',
    ).toString();
  }

  /// Cron session key.
  static String cronSession({String agentId = 'main', required String jobId}) =>
      SessionKey(agentId: agentId, scope: 'cron', identifiers: Uri.encodeComponent(jobId)).toString();

  /// Task session key.
  static String taskSession({String agentId = 'main', required String taskId}) {
    if (taskId.isEmpty) throw ArgumentError('taskId must not be empty');
    return SessionKey(agentId: agentId, scope: 'task', identifiers: Uri.encodeComponent(taskId)).toString();
  }
}
