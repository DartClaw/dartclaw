import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// A Slack user ID (`U…` or `W…`), the form `dm_allowlist` entries take.
final slackUserIdPattern = RegExp(r'^[UW][A-Z0-9]+$');

/// Configuration for the Slack channel.
class SlackConfig {
  /// Whether the Slack integration is enabled.
  final bool enabled;

  /// How Slack delivers events: `socket` or `events`.
  final String mode;

  /// Name of the `credentials` entry holding the bot token, or `null` when absent.
  final String? botTokenCredential;

  /// Name of the `credentials` entry holding the app-level token, or `null` when absent.
  final String? appTokenCredential;

  /// Name of the `credentials` entry holding the signing secret, or `null` when absent.
  final String? signingSecretCredential;

  /// HTTP path Slack's Events API requests are posted to in `events` mode.
  final String webhookPath;

  /// Direct-message access policy.
  final DmAccessMode dmAccess;

  /// Channel access policy.
  final GroupAccessMode groupAccess;

  /// Approved direct-message rows when [dmAccess] is allowlist-based.
  final List<GroupEntry> dmAllowlist;

  /// Approved channel rows when [groupAccess] is allowlist-based.
  final List<GroupEntry> groupAllowlist;

  /// Whether a channel message must mention the bot to open a thread.
  final bool requireMention;

  /// Additional regex patterns treated as bot mentions in channels.
  final List<String> mentionPatterns;

  /// Creates immutable Slack channel configuration.
  const new({
    this.enabled = false,
    this.mode = 'socket',
    this.botTokenCredential,
    this.appTokenCredential,
    this.signingSecretCredential,
    this.webhookPath = '/integrations/slack',
    this.dmAccess = DmAccessMode.allowlist,
    this.groupAccess = GroupAccessMode.disabled,
    this.dmAllowlist = const <GroupEntry>[],
    this.groupAllowlist = const <GroupEntry>[],
    this.requireMention = true,
    this.mentionPatterns = const [],
  });

  /// Creates a disabled Slack configuration.
  const new disabled() : this();

  /// The channel IDs from [groupAllowlist] as a plain string list.
  List<String> get groupIds => GroupEntry.groupIds(groupAllowlist);

  /// The sender IDs from [dmAllowlist] as a plain string list.
  List<String> get dmIds => GroupEntry.groupIds(dmAllowlist);

  /// Parses Slack configuration from YAML, appending warnings to [warns].
  factory fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final common = CommonChannelFields<GroupAccessMode>.fromYaml(
      'slack',
      yaml,
      warns,
      defaultDmAccess: DmAccessMode.allowlist,
      defaultGroupAccess: GroupAccessMode.disabled,
      parseGroupAccess: (value) => GroupAccessMode.values.asNameMap()[value],
    );

    return SlackConfig(
      enabled: common.enabled,
      mode: readString('mode', yaml, warns, defaultValue: 'socket', warnKey: 'slack.mode')!,
      botTokenCredential: readString('bot_token_credential', yaml, warns, warnKey: 'slack.bot_token_credential'),
      appTokenCredential: readString('app_token_credential', yaml, warns, warnKey: 'slack.app_token_credential'),
      signingSecretCredential: readString(
        'signing_secret_credential',
        yaml,
        warns,
        warnKey: 'slack.signing_secret_credential',
      ),
      webhookPath: readString(
        'webhook_path',
        yaml,
        warns,
        defaultValue: '/integrations/slack',
        warnKey: 'slack.webhook_path',
      )!,
      dmAccess: common.dmAccess,
      groupAccess: common.groupAccess,
      dmAllowlist: common.dmAllowlist,
      groupAllowlist: common.groupAllowlist,
      requireMention: common.requireMention,
      mentionPatterns: common.mentionPatterns,
    );
  }
}
