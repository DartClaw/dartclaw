import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show ContentGuardDisplayParams;
import 'package:dartclaw_server/src/templates/guard_config_summary.dart';
import 'package:test/test.dart';

void main() {
  group('extractGuardConfigs', () {
    test('returns empty list when guardChain is null', () {
      final configs = extractGuardConfigs(null);
      expect(configs, isEmpty);
    });

    test('extracts all 5 guard types, skipping ToolPolicyGuard', () {
      final chain = GuardChain(
        guards: [
          InputSanitizer(config: InputSanitizerConfig.defaults()),
          CommandGuard(config: CommandGuardConfig.defaults()),
          FileGuard(config: FileGuardConfig.defaults()),
          NetworkGuard(config: NetworkGuardConfig.defaults()),
          ToolPolicyGuard(cascade: ToolPolicyCascade()),
        ],
      );

      final configs = extractGuardConfigs(
        chain,
        contentGuardDisplay: const ContentGuardDisplayParams(enabled: true, classifier: 'claude_binary'),
      );

      // 4 from chain (ToolPolicyGuard skipped) + 1 ContentGuard = 5
      expect(configs, hasLength(5));
      expect(configs.map((c) => c.name).toList(), [
        'Input Sanitizer',
        'Command Guard',
        'File Guard',
        'Network Guard',
        'Content Guard',
      ]);
    });
  });

  group('CommandGuard extraction', () {
    test('shows pattern counts and pipe targets', () {
      final chain = GuardChain(
        guards: [CommandGuard(config: CommandGuardConfig.defaults())],
      );

      final configs = extractGuardConfigs(chain);
      final cmd = configs.firstWhere((c) => c.guardKey == 'command');

      expect(cmd.enabled, isTrue);
      expect(cmd.sections, hasLength(3)); // Pattern Categories, Blocked Pipes, Safe Pipes

      final patternSection = cmd.sections.first;
      expect(patternSection.label, 'Pattern Categories');
      for (final item in patternSection.items) {
        expect(item.value, contains('patterns'));
      }

      final blockedPipes = cmd.sections[1];
      expect(blockedPipes.label, 'Blocked Pipe Targets');
      expect(blockedPipes.items.first.style, 'mono');
    });
  });

  group('FileGuard extraction', () {
    test('groups rules by access level', () {
      final chain = GuardChain(
        guards: [FileGuard(config: FileGuardConfig.defaults())],
      );

      final configs = extractGuardConfigs(chain);
      final file = configs.firstWhere((c) => c.guardKey == 'file');

      expect(file.enabled, isTrue);
      final summarySection = file.sections.lastWhere((s) => s.label == 'Summary');
      final totalRules = summarySection.items.first;
      expect(totalRules.label, 'Total rules');
      expect(int.parse(totalRules.value), greaterThan(0));
    });
  });

  group('NetworkGuard extraction', () {
    test('shows domains and truncates at 15', () {
      final chain = GuardChain(
        guards: [NetworkGuard(config: NetworkGuardConfig.defaults())],
      );

      final configs = extractGuardConfigs(chain);
      final net = configs.firstWhere((c) => c.guardKey == 'network');

      expect(net.enabled, isTrue);
      final domainsSection = net.sections.firstWhere((s) => s.label == 'Allowed Domains');
      expect(domainsSection.items.first.style, 'mono');
    });

    test('includes agent overrides section when present', () {
      final chain = GuardChain(
        guards: [
          NetworkGuard(
            config: NetworkGuardConfig(
              allowedDomains: {'example.com'},
              exfilPatterns: [],
              agentOverrides: {
                'search': {'extra.com'},
              },
            ),
          ),
        ],
      );

      final configs = extractGuardConfigs(chain);
      final net = configs.firstWhere((c) => c.guardKey == 'network');
      final overrides = net.sections.where((s) => s.label == 'Agent Overrides');
      expect(overrides, hasLength(1));
      expect(overrides.first.items.first.value, '1');
    });
  });

  group('InputSanitizer extraction', () {
    test('shows enabled/channelsOnly badges and pattern categories', () {
      final chain = GuardChain(
        guards: [
          InputSanitizer(
            config: InputSanitizerConfig(
              enabled: true,
              channelsOnly: true,
              patterns: InputSanitizerConfig.defaults().patterns,
            ),
          ),
        ],
      );

      final configs = extractGuardConfigs(chain);
      final sanitizer = configs.firstWhere((c) => c.guardKey == 'input-sanitizer');

      expect(sanitizer.enabled, isTrue);
      final configSection = sanitizer.sections.firstWhere((s) => s.label == 'Configuration');
      final enabledItem = configSection.items.firstWhere((i) => i.label == 'Enabled');
      expect(enabledItem.value, 'Yes');
      expect(enabledItem.style, 'badge-success');

      final channelsItem = configSection.items.firstWhere((i) => i.label == 'Channels only');
      expect(channelsItem.value, 'Yes');

      final patternsSection = sanitizer.sections.firstWhere((s) => s.label == 'Pattern Categories');
      expect(patternsSection.items, isNotEmpty);
    });
  });

  group('ContentGuard extraction', () {
    test('claude_binary classifier shows N/A for API key', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        contentGuardDisplay: const ContentGuardDisplayParams(
          enabled: true,
          classifier: 'claude_binary',
          model: 'claude-sonnet-4-5-20250514',
          maxBytes: 50 * 1024,
          apiKeyConfigured: false,
        ),
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      expect(cg.enabled, isTrue);

      final configSection = cg.sections.first;
      final apiKeyItem = configSection.items.firstWhere((i) => i.label == 'API key');
      expect(apiKeyItem.value, 'N/A (OAuth)');
      expect(apiKeyItem.style, 'badge-muted');

      final modelItem = configSection.items.firstWhere((i) => i.label == 'Model');
      expect(modelItem.value, 'claude-sonnet-4-5-20250514');
    });

    test('anthropic_api classifier with no key shows Not configured', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        contentGuardDisplay: const ContentGuardDisplayParams(
          enabled: true,
          classifier: 'anthropic_api',
          apiKeyConfigured: false,
        ),
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      final configSection = cg.sections.first;
      final apiKeyItem = configSection.items.firstWhere((i) => i.label == 'API key');
      expect(apiKeyItem.value, 'Not configured');
    });

    test('anthropic_api classifier with key shows Configured', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        contentGuardDisplay: const ContentGuardDisplayParams(
          enabled: true,
          classifier: 'anthropic_api',
          apiKeyConfigured: true,
        ),
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      final configSection = cg.sections.first;
      final apiKeyItem = configSection.items.firstWhere((i) => i.label == 'API key');
      expect(apiKeyItem.value, 'Configured');
      expect(apiKeyItem.style, 'badge-success');
    });

    test('disabled content guard shows No', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        contentGuardDisplay: const ContentGuardDisplayParams(enabled: false),
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      expect(cg.enabled, isFalse);
      final enabledItem = cg.sections.first.items.firstWhere((i) => i.label == 'Enabled');
      expect(enabledItem.value, 'No');
      expect(enabledItem.style, 'badge-muted');
    });

    test('fail behavior displays correctly', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        contentGuardDisplay: const ContentGuardDisplayParams(enabled: true, failOpen: true),
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      final failItem = cg.sections.first.items.firstWhere((i) => i.label == 'Fail behavior');
      expect(failItem.value, 'Fail-open');
      expect(failItem.style, 'badge-muted');
    });
  });

  group('toTemplateMap', () {
    test('produces nested maps for Trellis rendering', () {
      final summary = GuardConfigSummary(
        name: 'Test Guard',
        guardKey: 'test',
        category: 'security',
        enabled: true,
        sections: [
          GuardConfigSection(
            label: 'Section 1',
            items: [GuardConfigItem(label: 'Key', value: 'Val', style: 'mono')],
          ),
        ],
      );

      final map = summary.toTemplateMap();
      expect(map['name'], 'Test Guard');
      expect(map['guardKey'], 'test');
      expect(map['enabled'], isTrue);

      final sections = map['sections'] as List;
      expect(sections, hasLength(1));

      final section = sections.first as Map<String, dynamic>;
      expect(section['label'], 'Section 1');

      final items = section['items'] as List;
      final item = items.first as Map<String, dynamic>;
      expect(item['label'], 'Key');
      expect(item['value'], 'Val');
      expect(item['style'], 'mono');
    });
  });
}
