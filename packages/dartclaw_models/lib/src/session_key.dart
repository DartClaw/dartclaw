/// Deterministic session key format: `agent:<agentId>:<scope>:<identifiers>`.
///
/// Factory methods pre-encode individual identifier components.
/// The [identifiers] field is stored as-is (already encoded by factories).
class SessionKey {
  /// Agent identifier embedded into the key prefix.
  final String agentId;

  /// Session scope such as `web`, `dm`, `group`, `cron`, or `task`.
  final String scope;

  /// Already-encoded trailing identifier payload for this scope.
  final String identifiers;

  /// Creates a parsed session key representation.
  const SessionKey({required this.agentId, required this.scope, this.identifiers = ''});

  /// Generates key string: `agent:<agentId>:<scope>:<identifiers>`.
  /// Identifiers are assumed to be pre-encoded by factory methods.
  @override
  String toString() => 'agent:$agentId:$scope:$identifiers';

  /// Parses a serialized key string back into a [SessionKey].
  factory SessionKey.parse(String key) {
    final parts = key.split(':');
    if (parts.length < 4 || parts[0] != 'agent') {
      throw FormatException('Invalid session key format: $key');
    }
    return SessionKey(agentId: parts[1], scope: parts[2], identifiers: parts.sublist(3).join(':'));
  }

  /// Builds the shared primary web session key for [agentId].
  static String webSession({String agentId = 'main'}) => SessionKey(agentId: agentId, scope: 'web').toString();

  /// Builds a shared DM session key used by all DM contacts for [agentId].
  static String dmShared({String agentId = 'main'}) =>
      SessionKey(agentId: agentId, scope: 'dm', identifiers: 'shared').toString();

  /// Builds a per-contact DM session key shared across channels.
  static String dmPerContact({String agentId = 'main', required String peerId}) {
    if (peerId.isEmpty) throw ArgumentError('peerId must not be empty');
    return SessionKey(agentId: agentId, scope: 'dm', identifiers: 'contact:${Uri.encodeComponent(peerId)}').toString();
  }

  /// Builds a per-channel per-contact DM session key.
  static String dmPerChannelContact({String agentId = 'main', required String channelType, required String peerId}) {
    if (peerId.isEmpty) throw ArgumentError('peerId must not be empty');
    return SessionKey(
      agentId: agentId,
      scope: 'dm',
      identifiers: '${Uri.encodeComponent(channelType)}:${Uri.encodeComponent(peerId)}',
    ).toString();
  }

  /// Builds a shared group session key for a channel group.
  static String groupShared({String agentId = 'main', required String channelType, required String groupId}) {
    if (groupId.isEmpty) throw ArgumentError('groupId must not be empty');
    return SessionKey(
      agentId: agentId,
      scope: 'group',
      identifiers: '${Uri.encodeComponent(channelType)}:${Uri.encodeComponent(groupId)}',
    ).toString();
  }

  /// Builds a per-member group session key inside a specific group.
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

  /// Builds a scheduled-job session key for [jobId].
  static String cronSession({String agentId = 'main', required String jobId}) =>
      SessionKey(agentId: agentId, scope: 'cron', identifiers: Uri.encodeComponent(jobId)).toString();

  /// Builds a task-linked session key for [taskId].
  static String taskSession({String agentId = 'main', required String taskId}) {
    if (taskId.isEmpty) throw ArgumentError('taskId must not be empty');
    return SessionKey(agentId: agentId, scope: 'task', identifiers: Uri.encodeComponent(taskId)).toString();
  }
}
