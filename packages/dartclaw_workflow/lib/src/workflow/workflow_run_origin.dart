import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ChannelType;

/// Surface names a run can be started from besides a chat channel.
const _nonChannelSurfaces = {'cron', 'github', 'cli', 'api', 'unknown'};

final _channelSurfaces = {for (final type in ChannelType.values) type.name};

/// Where a [WorkflowRun] was started, recorded once at start and never changed.
///
/// [surface] is a [ChannelType] name for a chat or web-chat start, otherwise
/// one of `cron`, `github`, `cli`, `api`, or `unknown`. The channel fields are
/// set only for a chat-channel start. Runs persisted before origin existed
/// read as [unknown].
class WorkflowRunOrigin {
  /// Where the run was started.
  final String surface;

  /// Channel type name of the originating chat turn.
  final String? channelType;

  /// Recipient the originating chat turn replies to.
  final String? recipientId;

  /// Thread identity within the recipient, when the channel threads.
  final String? threadId;

  /// Session key of the originating turn.
  final String? sessionKey;

  /// Sender of the originating chat message.
  final String? senderId;

  /// Creates an origin for [surface]. Only [fromJson] checks that it is a listed surface name.
  const new({required this.surface, this.channelType, this.recipientId, this.threadId, this.sessionKey, this.senderId});

  /// The origin of a run whose start was not recorded.
  static const unknown = WorkflowRunOrigin(surface: 'unknown');

  /// Serializes this origin to a JSON-ready map.
  Map<String, dynamic> toJson() => {
    'surface': surface,
    'channelType': channelType,
    'recipientId': recipientId,
    'threadId': threadId,
    'sessionKey': sessionKey,
    'senderId': senderId,
  };

  /// Reconstructs an origin from [json].
  ///
  /// A null [json] reads as [unknown]. A non-null value that is not a map of
  /// the known shape, or names an unlisted surface, throws a [FormatException]
  /// rather than inventing provenance.
  factory fromJson(Object? json) {
    if (json == null) return unknown;
    if (json is! Map) throw FormatException('Workflow run origin must be a JSON object, got ${json.runtimeType}');
    final surface = json['surface'];
    if (surface is! String || !(_nonChannelSurfaces.contains(surface) || _channelSurfaces.contains(surface))) {
      throw FormatException('Unknown workflow run origin surface: $surface');
    }
    return WorkflowRunOrigin(
      surface: surface,
      channelType: _optionalString(json, 'channelType'),
      recipientId: _optionalString(json, 'recipientId'),
      threadId: _optionalString(json, 'threadId'),
      sessionKey: _optionalString(json, 'sessionKey'),
      senderId: _optionalString(json, 'senderId'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkflowRunOrigin &&
      other.surface == surface &&
      other.channelType == channelType &&
      other.recipientId == recipientId &&
      other.threadId == threadId &&
      other.sessionKey == sessionKey &&
      other.senderId == senderId;

  @override
  int get hashCode => Object.hash(surface, channelType, recipientId, threadId, sessionKey, senderId);

  @override
  String toString() => 'WorkflowRunOrigin(${toJson()})';
}

String? _optionalString(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Workflow run origin "$key" must be a string, got ${value.runtimeType}');
  return value;
}
