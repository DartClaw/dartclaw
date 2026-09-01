import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'helpers.dart';

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

/// Display-oriented guard configuration for the settings template.
class GuardConfigSummary {
  final String name;
  final String guardKey;
  final String category;
  final bool enabled;
  final List<GuardConfigSection> sections;

  const new({
    required this.name,
    required this.guardKey,
    required this.category,
    required this.enabled,
    required this.sections,
  });

  Map<String, dynamic> toTemplateMap() => {
    'name': name,
    'guardKey': guardKey,
    'category': category,
    'enabled': enabled,
    'sections': sections.map((s) => s.toTemplateMap()).toList(),
  };
}

/// Groups [GuardConfigItem]s under a labelled section in the guard summary template.
class GuardConfigSection {
  final String label;
  final List<GuardConfigItem> items;

  const new({required this.label, required this.items});

  Map<String, dynamic> toTemplateMap() => {'label': label, 'items': items.map((i) => i.toTemplateMap()).toList()};
}

/// Represents a single labelled value rendered inside a [GuardConfigSection].
class GuardConfigItem {
  final String label;
  final String value;
  final String style;

  const new({required this.label, required this.value, this.style = 'default'});

  Map<String, dynamic> toTemplateMap() => {'label': label, 'value': value, 'style': style};
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// Extracts display-oriented guard config from the guard chain and content guard.
List<GuardConfigSummary> extractGuardConfigs(
  GuardChain? guardChain, {
  required SecurityConfig security,
  bool apiKeyConfigured = false,
  bool failOpen = false,
}) {
  if (guardChain == null) return [];

  final summaries = <GuardConfigSummary>[];

  for (final guard in guardChain.guards) {
    // Skip policy guards (internal, not user-configurable).
    if (guard.category == 'policy') continue;

    if (guard is CommandGuard) {
      summaries.add(_extractCommandGuard(guard));
    } else if (guard is FileGuard) {
      summaries.add(_extractFileGuard(guard));
    } else if (guard is NetworkGuard) {
      summaries.add(_extractNetworkGuard(guard));
    }
  }

  summaries.add(_buildContentGuardSummary(security, apiKeyConfigured: apiKeyConfigured, failOpen: failOpen));

  return summaries;
}

// ---------------------------------------------------------------------------
// Per-guard extractors
// ---------------------------------------------------------------------------

GuardConfigSummary _extractCommandGuard(CommandGuard guard) {
  final cfg = guard.config;

  // Count patterns by category.
  final categories = {
    'Destructive': cfg.destructivePatterns.length,
    'Force': cfg.forcePatterns.length,
    'Fork bomb': cfg.forkBombPatterns.length,
    'Interpreter escape': cfg.interpreterEscapes.length,
  };

  return GuardConfigSummary(
    name: 'Command Guard',
    guardKey: 'command',
    category: guard.category,
    enabled: true,
    sections: [
      GuardConfigSection(
        label: 'Pattern Categories',
        items: categories.entries.map((e) => GuardConfigItem(label: e.key, value: '${e.value} patterns')).toList(),
      ),
      GuardConfigSection(
        label: 'Blocked Pipe Targets',
        items: [GuardConfigItem(label: 'Targets', value: cfg.blockedPipeTargets.toList().join(', '), style: 'mono')],
      ),
    ],
  );
}

GuardConfigSummary _extractFileGuard(FileGuard guard) {
  final cfg = guard.config;

  // Group rules by access level.
  final grouped = <FileAccessLevel, List<String>>{};
  for (final rule in cfg.rules) {
    grouped.putIfAbsent(rule.level, () => []).add(rule.pattern);
  }

  final levelLabels = {
    FileAccessLevel.noAccess: 'No Access',
    FileAccessLevel.readOnly: 'Read Only',
    FileAccessLevel.noDelete: 'No Delete',
  };

  return GuardConfigSummary(
    name: 'File Guard',
    guardKey: 'file',
    category: guard.category,
    enabled: true,
    sections: [
      for (final level in FileAccessLevel.values)
        if (grouped.containsKey(level))
          GuardConfigSection(
            label: levelLabels[level] ?? level.name,
            items: grouped[level]!.map((p) => GuardConfigItem(label: p, value: '', style: 'mono')).toList(),
          ),
      GuardConfigSection(
        label: 'Summary',
        items: [GuardConfigItem(label: 'Total rules', value: '${cfg.rules.length}')],
      ),
    ],
  );
}

GuardConfigSummary _extractNetworkGuard(NetworkGuard guard) {
  final cfg = guard.config;

  final domains = cfg.allowedDomains.toList()..sort();
  final truncated = domains.length > 15;
  final displayDomains = truncated ? domains.sublist(0, 15) : domains;
  final domainSuffix = truncated ? ' (+ ${domains.length - 15} more)' : '';

  return GuardConfigSummary(
    name: 'Network Guard',
    guardKey: 'network',
    category: guard.category,
    enabled: true,
    sections: [
      GuardConfigSection(
        label: 'Allowed Domains',
        items: [GuardConfigItem(label: 'Domains', value: '${displayDomains.join(", ")}$domainSuffix', style: 'mono')],
      ),
      GuardConfigSection(
        label: 'Exfiltration Patterns',
        items: [GuardConfigItem(label: 'Built-in patterns', value: '${cfg.exfilPatterns.length}')],
      ),
      if (cfg.agentOverrides.isNotEmpty)
        GuardConfigSection(
          label: 'Agent Overrides',
          items: [GuardConfigItem(label: 'Override count', value: '${cfg.agentOverrides.length}')],
        ),
    ],
  );
}

GuardConfigSummary _buildContentGuardSummary(
  SecurityConfig security, {
  required bool apiKeyConfigured,
  required bool failOpen,
}) {
  final classifier = security.contentGuardClassifier;
  final isClaudeBinary = classifier == 'claude_binary';
  final apiKeyDisplay = isClaudeBinary ? 'N/A (OAuth)' : (apiKeyConfigured ? 'Configured' : 'Not configured');
  final apiKeyStyle = isClaudeBinary ? 'badge-muted' : (apiKeyConfigured ? 'badge-success' : 'badge-muted');

  return GuardConfigSummary(
    name: 'Content Guard',
    guardKey: 'content-guard',
    category: 'content',
    enabled: security.contentGuardEnabled,
    sections: [
      GuardConfigSection(
        label: 'Configuration',
        items: [
          GuardConfigItem(
            label: 'Enabled',
            value: security.contentGuardEnabled ? 'Yes' : 'No',
            style: security.contentGuardEnabled ? 'badge-success' : 'badge-muted',
          ),
          GuardConfigItem(label: 'Classifier', value: classifier, style: 'mono'),
          GuardConfigItem(
            label: 'Model',
            value: security.contentGuardModel.isNotEmpty ? security.contentGuardModel : '-',
            style: 'mono',
          ),
          GuardConfigItem(label: 'Max content', value: formatBytes(security.contentGuardMaxBytes)),
          GuardConfigItem(label: 'API key', value: apiKeyDisplay, style: apiKeyStyle),
          GuardConfigItem(
            label: 'Fail behavior',
            value: failOpen ? 'Fail-open' : 'Fail-closed',
            style: failOpen ? 'badge-muted' : 'badge-success',
          ),
        ],
      ),
    ],
  );
}
