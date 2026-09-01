import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// One tab in the settings tab strip.
class SettingsTab {
  /// Fragment id, also the `data-tab` value the panels carry.
  final String id;

  /// Label shown in the strip.
  final String label;

  /// Creates a [SettingsTab] value.
  const new({required this.id, required this.label});
}

/// One card on the settings page.
///
/// A panel claiming registry [prefixes] renders its fields from the shared
/// form fragment; a panel claiming none is server-rendered markup that owns its
/// own content (channel summaries, provider cards, the guard editor).
class SettingsPanel {
  /// Panel id without the `panel-` prefix.
  final String id;

  /// Id of the [SettingsTab] this panel appears under.
  final String tab;

  /// Card title.
  final String title;

  /// Registry prefixes this panel claims. A prefix matches a field whose
  /// `yamlPath` equals it or starts with it followed by a dot.
  final List<String> prefixes;

  /// Route a card-footer link points at, or `null` for no footer link.
  final String? linkHref;

  /// Label of that link.
  final String? linkLabel;

  /// Creates a [SettingsPanel] value.
  const new({
    required this.id,
    required this.tab,
    required this.title,
    this.prefixes = const [],
    this.linkHref,
    this.linkLabel,
  });

  /// Whether this panel renders registry fields rather than bespoke markup.
  bool get isForm => prefixes.isNotEmpty;

  /// DOM id of the panel element.
  String get elementId => 'panel-$id';
}

/// The settings tab strip, in display order.
const settingsTabs = <SettingsTab>[
  SettingsTab(id: 'agent', label: 'Agent'),
  SettingsTab(id: 'workflow', label: 'Workflows'),
  SettingsTab(id: 'server', label: 'Server'),
  SettingsTab(id: 'sessions', label: 'Sessions'),
  SettingsTab(id: 'memory', label: 'Memory'),
  SettingsTab(id: 'knowledge', label: 'Knowledge'),
  SettingsTab(id: 'context', label: 'Context'),
  SettingsTab(id: 'tasks', label: 'Tasks'),
  SettingsTab(id: 'scheduling', label: 'Scheduling'),
  SettingsTab(id: 'channels', label: 'Channels'),
  SettingsTab(id: 'providers', label: 'Providers'),
  SettingsTab(id: 'governance', label: 'Governance'),
  SettingsTab(id: 'security', label: 'Security'),
];

/// Every settings panel, in DOM order.
///
/// Together with [settingsFieldOwners] this is the total assignment of
/// [ConfigMeta.fields]: `test/web/settings_form_test.dart` fails on a
/// registered field that neither a panel prefix nor an owner entry claims, and
/// on a prefix two panels both declare.
const settingsPanels = <SettingsPanel>[
  SettingsPanel(
    id: 'agent',
    tab: 'agent',
    title: 'Agent Configuration',
    prefixes: ['agent', 'harness', 'container', 'mcp_servers'],
  ),
  SettingsPanel(id: 'workflow', tab: 'workflow', title: 'Workflow Defaults', prefixes: ['workflow']),
  SettingsPanel(
    id: 'server-config',
    tab: 'server',
    title: 'Server Configuration',
    prefixes: [
      'port',
      'host',
      'name',
      'base_url',
      'data_dir',
      'dev_mode',
      'source_dir',
      'static_dir',
      'templates_dir',
      'concurrency',
      'logging',
      'features',
      'onboarding',
    ],
  ),
  SettingsPanel(
    id: 'server-gateway',
    tab: 'server',
    title: 'Gateway and Authentication',
    prefixes: ['gateway', 'auth'],
  ),
  SettingsPanel(id: 'server-github', tab: 'server', title: 'GitHub Webhook', prefixes: ['github']),
  SettingsPanel(id: 'server-git-sync', tab: 'server', title: 'Workspace Git Sync', prefixes: ['workspace']),
  SettingsPanel(id: 'sessions', tab: 'sessions', title: 'Sessions', prefixes: ['sessions']),
  SettingsPanel(id: 'memory', tab: 'memory', title: 'Memory Configuration', prefixes: ['memory', 'search']),
  SettingsPanel(id: 'knowledge', tab: 'knowledge', title: 'Knowledge', prefixes: ['knowledge']),
  SettingsPanel(id: 'context', tab: 'context', title: 'Context', prefixes: ['context']),
  SettingsPanel(id: 'tasks', tab: 'tasks', title: 'Tasks and Projects', prefixes: ['tasks', 'projects']),
  SettingsPanel(
    id: 'scheduling',
    tab: 'scheduling',
    title: 'Scheduling',
    prefixes: ['scheduling'],
    linkHref: '/scheduling',
    linkLabel: 'View Schedule',
  ),
  SettingsPanel(
    id: 'providers-config',
    tab: 'providers',
    title: 'Provider Registry',
    prefixes: ['providers', 'credentials'],
  ),
  SettingsPanel(id: 'governance', tab: 'governance', title: 'Governance', prefixes: ['governance', 'usage', 'alerts']),
  SettingsPanel(id: 'security-config', tab: 'security', title: 'Security', prefixes: ['security', 'guard_audit']),
  SettingsPanel(id: 'channel-whatsapp', tab: 'channels', title: 'WhatsApp Channel'),
  SettingsPanel(id: 'channel-signal', tab: 'channels', title: 'Signal Channel'),
  SettingsPanel(id: 'channel-googlechat', tab: 'channels', title: 'Google Chat Channel'),
  SettingsPanel(id: 'providers', tab: 'providers', title: 'Providers'),
  SettingsPanel(id: 'server-auth', tab: 'server', title: 'Authentication'),
  SettingsPanel(id: 'server-health', tab: 'server', title: 'System Health'),
  SettingsPanel(id: 'security', tab: 'security', title: 'Security & Guards'),
  SettingsPanel(id: 'server-workspace', tab: 'server', title: 'Workspace'),
];

/// Registry prefixes another settings surface owns, keyed by prefix with the
/// surface that owns them.
///
/// These are deliberately absent from [settingsPanels]: rendering them here
/// would give an operator two places to change one field.
const settingsFieldOwners = <String, String>{
  'channels': 'Channel detail pages under /settings/channels/<type>',
  'guards': 'The guard editor on the Security tab',
};

/// The panel [yamlPath] belongs to, or `null` when no panel claims it.
SettingsPanel? settingsPanelForField(String yamlPath) {
  SettingsPanel? best;
  var bestLength = -1;
  for (final panel in settingsPanels) {
    for (final prefix in panel.prefixes) {
      if (!_prefixMatches(prefix, yamlPath) || prefix.length <= bestLength) continue;
      best = panel;
      bestLength = prefix.length;
    }
  }
  final owner = _ownerPrefixFor(yamlPath);
  // Longest prefix wins across both maps, mirroring the registry's
  // exact-path-wins rule: an owner prefix only loses to a more specific panel.
  if (owner != null && owner.length > bestLength) return null;
  return best;
}

/// The surface that owns [yamlPath] instead of the settings form, or `null`.
String? settingsFieldOwnerFor(String yamlPath) {
  final prefix = _ownerPrefixFor(yamlPath);
  return prefix == null ? null : settingsFieldOwners[prefix];
}

/// Every registered field the given panel renders.
///
/// Ordered by the panel's own declared prefixes first and registry order within
/// each, so a panel reads in the order it declares rather than in the order the
/// registry's `part` files happen to be spread.
List<FieldMeta> settingsFieldsForPanel(SettingsPanel panel) {
  final claimed = [
    for (final field in ConfigMeta.fields.values)
      if (settingsPanelForField(field.yamlPath)?.id == panel.id) field,
  ];
  return [
    for (final prefix in panel.prefixes)
      for (final field in claimed)
        if (_prefixMatches(prefix, field.yamlPath) && _longestClaimedPrefix(panel, field.yamlPath) == prefix) field,
  ];
}

String _longestClaimedPrefix(SettingsPanel panel, String yamlPath) {
  var best = '';
  for (final prefix in panel.prefixes) {
    if (_prefixMatches(prefix, yamlPath) && prefix.length > best.length) best = prefix;
  }
  return best;
}

String? _ownerPrefixFor(String yamlPath) {
  String? best;
  for (final prefix in settingsFieldOwners.keys) {
    if (!_prefixMatches(prefix, yamlPath)) continue;
    if (best == null || prefix.length > best.length) best = prefix;
  }
  return best;
}

bool _prefixMatches(String prefix, String yamlPath) => yamlPath == prefix || yamlPath.startsWith('$prefix.');
