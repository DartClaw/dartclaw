import 'package:dartclaw_core/dartclaw_core.dart';

import '../params/display_params.dart';
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

  const GuardConfigSummary({
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

class GuardConfigSection {
  final String label;
  final List<GuardConfigItem> items;

  const GuardConfigSection({required this.label, required this.items});

  Map<String, dynamic> toTemplateMap() => {'label': label, 'items': items.map((i) => i.toTemplateMap()).toList()};
}

class GuardConfigItem {
  final String label;
  final String value;
  final String style;

  const GuardConfigItem({required this.label, required this.value, this.style = 'default'});

  Map<String, dynamic> toTemplateMap() => {'label': label, 'value': value, 'style': style};
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// Extracts display-oriented guard config from the guard chain and content guard.
List<GuardConfigSummary> extractGuardConfigs(
  GuardChain? guardChain, {
  ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams(),
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
    } else if (guard is InputSanitizer) {
      summaries.add(_extractInputSanitizer(guard));
    }
  }

  // ContentGuard is not in the chain — add from separate params.
  summaries.add(_buildContentGuardSummary(contentGuardDisplay));

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
      GuardConfigSection(
        label: 'Safe Pipe Targets',
        items: [GuardConfigItem(label: 'Targets', value: cfg.safePipeTargets.toList().join(', '), style: 'mono')],
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

GuardConfigSummary _extractInputSanitizer(InputSanitizer guard) {
  final cfg = guard.config;

  // Count patterns by category.
  final categoryCounts = <String, int>{};
  for (final p in cfg.patterns) {
    categoryCounts[p.category] = (categoryCounts[p.category] ?? 0) + 1;
  }

  return GuardConfigSummary(
    name: 'Input Sanitizer',
    guardKey: 'input-sanitizer',
    category: guard.category,
    enabled: cfg.enabled,
    sections: [
      GuardConfigSection(
        label: 'Configuration',
        items: [
          GuardConfigItem(
            label: 'Enabled',
            value: cfg.enabled ? 'Yes' : 'No',
            style: cfg.enabled ? 'badge-success' : 'badge-muted',
          ),
          GuardConfigItem(
            label: 'Channels only',
            value: cfg.channelsOnly ? 'Yes' : 'No',
            style: cfg.channelsOnly ? 'badge-success' : 'badge-muted',
          ),
        ],
      ),
      GuardConfigSection(
        label: 'Pattern Categories',
        items: categoryCounts.entries.map((e) => GuardConfigItem(label: e.key, value: '${e.value} patterns')).toList(),
      ),
    ],
  );
}

GuardConfigSummary _buildContentGuardSummary(ContentGuardDisplayParams p) {
  final isClaudeBinary = p.classifier == 'claude_binary';
  final apiKeyDisplay = isClaudeBinary ? 'N/A (OAuth)' : (p.apiKeyConfigured ? 'Configured' : 'Not configured');
  final apiKeyStyle = isClaudeBinary ? 'badge-muted' : (p.apiKeyConfigured ? 'badge-success' : 'badge-muted');

  return GuardConfigSummary(
    name: 'Content Guard',
    guardKey: 'content-guard',
    category: 'content',
    enabled: p.enabled,
    sections: [
      GuardConfigSection(
        label: 'Configuration',
        items: [
          GuardConfigItem(
            label: 'Enabled',
            value: p.enabled ? 'Yes' : 'No',
            style: p.enabled ? 'badge-success' : 'badge-muted',
          ),
          GuardConfigItem(label: 'Classifier', value: p.classifier, style: 'mono'),
          GuardConfigItem(label: 'Model', value: p.model.isNotEmpty ? p.model : '-', style: 'mono'),
          GuardConfigItem(label: 'Max content', value: formatBytes(p.maxBytes)),
          GuardConfigItem(label: 'API key', value: apiKeyDisplay, style: apiKeyStyle),
          GuardConfigItem(
            label: 'Fail behavior',
            value: p.failOpen ? 'Fail-open' : 'Fail-closed',
            style: p.failOpen ? 'badge-muted' : 'badge-success',
          ),
        ],
      ),
    ],
  );
}
