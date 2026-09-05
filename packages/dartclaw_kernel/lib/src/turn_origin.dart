/// Where a human-facing turn arrived from, as composed into the system prompt.
///
/// [channel] is a `ChannelType` name; [contact] is the sender's display name
/// when the channel reported one, else the sender identifier; [group] marks a
/// group conversation. Absent for turns with no human channel of origin
/// (logical agents, tasks, scheduled jobs).
typedef TurnOrigin = ({String channel, String? contact, bool group});
