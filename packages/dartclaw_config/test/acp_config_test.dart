import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('ACP harness config', () {
    test('direct construction retains normalized lookup compatibility', () {
      const agent = AcpAgentConfig(binary: 'goose');
      const config = AcpConfig(agents: {' Goose ': agent});

      expect(config['goose'], same(agent));
    });

    test('direct construction never routes blank IDs to a default provider', () {
      const agent = AcpAgentConfig(binary: 'goose');
      const config = AcpConfig(agents: {'claude': agent, ' ': agent});

      expect(config[' '], isNull);
      expect(const AcpConfig(agents: {' ': agent})['claude'], isNull);
    });

    test('direct construction rejects normalized lookup collisions', () {
      const first = AcpAgentConfig(binary: 'goose-first');
      const second = AcpAgentConfig(binary: 'goose-second');
      const config = AcpConfig(agents: {'Goose': first, ' goose ': second});

      expect(() => config['goose'], throwsStateError);
    });

    test('parses a guarded direct ACP agent without provider capacity coupling', () {
      final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: anthropic
        verification: a0_1_goose_direct
        requires_guard_mediation: true
        required_builtins: ["developer"]
        container_isolation_required: false
providers:
  goose:
    executable: goose
    pool_size: 2
''');

      final goose = config.harness.acp['goose'];

      expect(goose, isNotNull);
      expect(goose!.binary, 'goose');
      expect(goose.args, ['acp', '--with-builtin', 'developer']);
      expect(goose.topology, AcpAgentTopology.direct);
      expect(goose.modelProvider, 'anthropic');
      expect(goose.verification, 'a0_1_goose_direct');
      expect(goose.requiresGuardMediation, isTrue);
      expect(goose.requiredBuiltins, ['developer']);
      expect(goose.containerIsolationRequired, isFalse);
      expect(goose.securityClassification, AcpSecurityClassification.guardMediated);
      expect(config.providers['goose']!.poolSize, 2);
      expect(config.warnings, isEmpty);
    });

    test('normalizes ACP provider IDs and rejects normalization collisions', () {
      final config = loadYaml('''
harness:
  acp:
    agents:
      Goose:
        binary: goose-first
        topology: direct
      goose:
        binary: goose-second
        topology: direct
''');

      expect(config.harness.acp.agents.keys, ['goose']);
      expect(config.harness.acp['GOOSE']?.binary, 'goose-first');
      expect(config.warnings, anyElement(contains('collides with another provider after normalization')));
    });

    test('skips missing binary without creating an agent', () {
      final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        args: ["acp"]
''');

      expect(config.harness.acp.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('harness.acp.agents.goose missing "binary"')));
    });

    test('rejects guarded relay and unverified configs before spawn', () {
      for (final topology in ['relay', 'unverified']) {
        final config = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: $topology
        model_provider: anthropic
        verification: evidence
        requires_guard_mediation: true
        required_builtins: ["developer"]
''');

        expect(config.harness.acp.isEmpty, isTrue);
        expect(config.warnings, anyElement(contains('requires_guard_mediation requires topology "direct"')));
      }
    });

    test('rejects guarded configs missing verification developer builtin or using relay selectors', () {
      final cases = {
        'missing verification': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: anthropic
        requires_guard_mediation: true
''',
        'missing developer': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp"]
        topology: direct
        model_provider: anthropic
        verification: evidence
        requires_guard_mediation: true
''',
        'claude-acp relay': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: claude-acp
        verification: evidence
        requires_guard_mediation: true
        required_builtins: ["developer"]
''',
        'codex-acp relay': '''
harness:
  acp:
    agents:
      goose:
        binary: goose
        args: ["acp", "--with-builtin", "developer"]
        topology: direct
        model_provider: codex-acp
        verification: evidence
        requires_guard_mediation: true
        required_builtins: ["developer"]
''',
      };

      for (final yaml in cases.values) {
        final config = loadYaml(yaml);
        expect(config.harness.acp.isEmpty, isTrue);
      }
    });

    test('requires container isolation metadata for unguarded relay and unverified configs', () {
      final rejected = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: relay
''');
      final accepted = loadYaml('''
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: unverified
        container_isolation_required: true
        container_profile: restricted
      vibe:
        binary: vibe-acp
        topology: relay
        container_isolation_required: true
        container_profile: workspace
''');

      expect(rejected.harness.acp.isEmpty, isTrue);
      expect(rejected.warnings, anyElement(contains('container_isolation_required: true')));
      expect(accepted.harness.acp['goose']!.containerProfile, AcpContainerProfile.restricted);
      expect(accepted.harness.acp['vibe']!.containerProfile, AcpContainerProfile.workspace);
      expect(accepted.harness.acp['goose']!.securityClassification, AcpSecurityClassification.hostOnly);
      expect(accepted.warnings, isEmpty);
    });

    /// `credential` is the only path by which a DartClaw-managed credential
    /// reaches an ACP agent, so a reference that cannot be presented has to be
    /// visible at load — the spawn itself is silent about it.
    group('credential reference', () {
      String yamlWithCredential(String reference) =>
          '''
credentials:
  anthropic:
    api_key: \${ANTHROPIC_API_KEY}
  literal:
    api_key: sk-literal
  project:
    type: github-token
    token: \${GITHUB_TOKEN}
harness:
  acp:
    agents:
      goose:
        binary: goose
        topology: direct
        credential: $reference
''';

      const env = {'HOME': defaultTestHome, 'ANTHROPIC_API_KEY': 'sk-ant-configured', 'GITHUB_TOKEN': 'ghp-configured'};

      test('an api_key entry parses and survives an equality round-trip', () {
        final config = loadYaml(yamlWithCredential('anthropic'), env: env);

        expect(config.harness.acp['goose']!.credential, 'anthropic');
        expect(config.warnings, isEmpty);
        expect(
          config.harness.acp['goose'],
          const AcpAgentConfig(binary: 'goose', topology: AcpAgentTopology.direct, credential: 'anthropic'),
        );
        expect(
          const AcpAgentConfig(binary: 'goose', credential: 'anthropic'),
          isNot(const AcpAgentConfig(binary: 'goose')),
          reason: 'a dropped field in == would let a credentialed registration compare equal to an isolated one',
        );
      });

      test('an unpresentable reference warns and leaves the agent uncredentialed', () {
        final cases = {
          'openai': 'is not a configured credentials entry',
          'project': 'is not an api_key credential',
          'literal': 'is a literal value with no environment variable name',
        };

        for (final entry in cases.entries) {
          final config = loadYaml(yamlWithCredential(entry.key), env: env);

          expect(config.harness.acp['goose']!.credential, isNull, reason: entry.key);
          expect(
            config.warnings,
            anyElement(allOf(contains('harness.acp.agents.goose.credential'), contains(entry.value))),
            reason: entry.key,
          );
        }
      });

      test('an entry whose environment variable is unset warns rather than presenting an empty key', () {
        final config = loadYaml(yamlWithCredential('anthropic'), env: const {'HOME': defaultTestHome});

        expect(config.harness.acp['goose']!.credential, isNull);
        expect(config.warnings, anyElement(contains('resolves to an empty value')));
      });
    });
  });
}
