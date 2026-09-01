import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/templates/guard_config_summary.dart';
import 'package:test/test.dart';

void main() {
  group('extractGuardConfigs', () {
    test('returns empty list when guardChain is null', () {
      final configs = extractGuardConfigs(null, security: const SecurityConfig());
      expect(configs, isEmpty);
    });

    test('extracts every configurable guard, skipping ToolPolicyGuard', () {
      final chain = GuardChain(
        guards: [
          CommandGuard(config: CommandGuardConfig.defaults()),
          FileGuard(config: FileGuardConfig.defaults()),
          NetworkGuard(config: NetworkGuardConfig.defaults()),
          ToolPolicyGuard(cascade: ToolPolicyCascade()),
        ],
      );

      final configs = extractGuardConfigs(
        chain,
        security: const SecurityConfig(contentGuardEnabled: true, contentGuardClassifier: 'claude_binary'),
      );

      // 3 from chain (ToolPolicyGuard skipped) + 1 ContentGuard = 4
      expect(configs, hasLength(4));
      expect(configs.map((c) => c.guardKey), isNot(contains('input-sanitizer')));
      expect(configs.expand((c) => c.sections).map((s) => s.label), isNot(contains('Safe Pipe Targets')));
      expect(configs.map((c) => c.name).toList(), ['Command Guard', 'File Guard', 'Network Guard', 'Content Guard']);
    });
  });

  group('CommandGuard extraction', () {
    test('shows pattern counts and pipe targets', () {
      final chain = GuardChain(guards: [CommandGuard(config: CommandGuardConfig.defaults())]);

      final configs = extractGuardConfigs(chain, security: const SecurityConfig());
      final cmd = configs.firstWhere((c) => c.guardKey == 'command');

      expect(cmd.enabled, isTrue);
      expect(cmd.sections, hasLength(2)); // Pattern Categories, Blocked Pipe Targets

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
      final chain = GuardChain(guards: [FileGuard(config: FileGuardConfig.defaults())]);

      final configs = extractGuardConfigs(chain, security: const SecurityConfig());
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
      final chain = GuardChain(guards: [NetworkGuard(config: NetworkGuardConfig.defaults())]);

      final configs = extractGuardConfigs(chain, security: const SecurityConfig());
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

      final configs = extractGuardConfigs(chain, security: const SecurityConfig());
      final net = configs.firstWhere((c) => c.guardKey == 'network');
      final overrides = net.sections.where((s) => s.label == 'Agent Overrides');
      expect(overrides, hasLength(1));
      expect(overrides.first.items.first.value, '1');
    });
  });

  group('ContentGuard extraction', () {
    test('claude_binary classifier shows N/A for API key', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        security: const SecurityConfig(
          contentGuardEnabled: true,
          contentGuardClassifier: 'claude_binary',
          contentGuardModel: 'sonnet',
          contentGuardMaxBytes: 50 * 1024,
        ),
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      expect(cg.enabled, isTrue);

      final configSection = cg.sections.first;
      final apiKeyItem = configSection.items.firstWhere((i) => i.label == 'API key');
      expect(apiKeyItem.value, 'N/A (OAuth)');
      expect(apiKeyItem.style, 'badge-muted');

      final modelItem = configSection.items.firstWhere((i) => i.label == 'Model');
      expect(modelItem.value, 'sonnet');
    });

    test('anthropic_api classifier with no key shows Not configured', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        security: const SecurityConfig(contentGuardEnabled: true, contentGuardClassifier: 'anthropic_api'),
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      final configSection = cg.sections.first;
      final apiKeyItem = configSection.items.firstWhere((i) => i.label == 'API key');
      expect(apiKeyItem.value, 'Not configured');
    });

    test('anthropic_api classifier with key shows Configured', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        security: const SecurityConfig(contentGuardEnabled: true, contentGuardClassifier: 'anthropic_api'),
        apiKeyConfigured: true,
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
        security: const SecurityConfig(contentGuardEnabled: false),
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
        security: const SecurityConfig(contentGuardEnabled: true),
        failOpen: true,
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      final failItem = cg.sections.first.items.firstWhere((i) => i.label == 'Fail behavior');
      expect(failItem.value, 'Fail-open');
      expect(failItem.style, 'badge-muted');
    });

    test('effective fail-closed wins over configured fail-open', () {
      final configs = extractGuardConfigs(
        GuardChain(guards: []),
        security: const SecurityConfig(contentGuardEnabled: true, contentGuardFailOpen: true),
        failOpen: false,
      );

      final cg = configs.firstWhere((c) => c.guardKey == 'content-guard');
      final failItem = cg.sections.first.items.firstWhere((i) => i.label == 'Fail behavior');
      expect(failItem.value, 'Fail-closed');
      expect(failItem.style, 'badge-success');
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
