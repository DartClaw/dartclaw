import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' show loadYamlNode;

import 'support/load_config.dart';

void main() {
  group('config path sweep', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    test('an undescribed sibling under a registered section is collected', () {
      expect(_sweep('guard_audit:\n  max_retention_days: 30\n  made_up: 1\n').unaccepted, const [
        'guard_audit.made_up',
      ]);
    });

    test('an operator-named entry is accepted whole, whatever its shape declares', () {
      // The owning parser keeps its own entry vocabulary — providers.<id> puts
      // every key it does not name into ProviderEntry.options on purpose, and
      // `dartclaw init` writes two of them.
      expect(
        _sweep('providers:\n  claude:\n    executable: claude\n    auth_method: oauth\n    model: sonnet\n').unaccepted,
        isEmpty,
      );
      expect(_sweep('mcp_servers:\n  acme:\n    url: https://x\n    env:\n      TOKEN: v\n').unaccepted, isEmpty);
      expect(_sweep('alerts:\n  routes:\n    task_failed: [ops]\n').unaccepted, isEmpty);
    });

    test('a registered container is a leaf only where the registry describes nothing below it', () {
      // `channels` is registered readonly with an OpaqueEntry so the block is
      // describable and un-writable. That must not turn the described built-in
      // channel fields under it into an unswept subtree — the concrete
      // `channels.*` registrations exist so a typo there still refuses the load.
      expect(_sweep('channels:\n  google_chat:\n    enabled: true\n    typoo: 1\n').unaccepted, const [
        'channels.google_chat.typoo',
      ]);

      // The other half of the same rule: descending into a container never
      // judges its operator-named entries, whose keys the owning parser owns.
      expect(_sweep('providers:\n  claude:\n    executable: claude\n    unnamed_option: 1\n').unaccepted, isEmpty);
      expect(
        _sweep('projects:\n  fetchCooldownMinutes: 10\n  acme:\n    remote: https://x\n    unnamed_option: 1\n')
            .unaccepted,
        isEmpty,
      );
    });

    test('a list value is a leaf, so nothing inside an element is judged', () {
      expect(_sweep('github:\n  triggers:\n    - event: issues\n      typo: 1\n').unaccepted, isEmpty);
    });

    test('a subtree under a registered extension key is accepted whole', () {
      DartclawConfig.registerExtensionParser('slack', (yaml, warns) => yaml);
      expect(_sweep('slack:\n  webhook: https://example.com\n  anything: {deep: 1}\n').unaccepted, isEmpty);
    });

    test('a subtree-mode accept-set row is accepted whole; an exact-mode row is not', () {
      expect(_sweep('andthen:\n  git_url: x\n  nested:\n    deeper: 1\n').unaccepted, isEmpty);
      expect(_sweep('guard_audit:\n  max_entries:\n    nested: 1\n').unaccepted, const [
        'guard_audit.max_entries.nested',
      ]);
    });

    test('the sweep names no path of its own — every decision comes from its inputs', () {
      final empty = DartclawConfig.sweepConfigPathsForTesting(
        _yaml('port: 3000\nagent:\n  model: sonnet\n'),
        fields: const {},
        tolerated: const {},
      );
      expect(empty.unaccepted, const ['port', 'agent']);
    });

    test('a deregistered path with an accept-set row warns instead of refusing the load', () {
      // The handoff a sibling story performs: the path leaves ConfigMeta and
      // arrives in the accept-set in the same change.
      final registry = Map<String, FieldMeta>.of(ConfigMeta.fields)..remove('agent.max_turns');
      const row = ToleratedLegacyKey(
        path: 'agent.max_turns',
        match: LegacyKeyMatch.exact,
        replacement: 'Removed turn cap; the harness decides when a turn ends.',
      );

      final handedOver = DartclawConfig.sweepConfigPathsForTesting(
        _yaml('agent:\n  max_turns: 40\n'),
        fields: registry,
        tolerated: {...ConfigMeta.toleratedLegacyKeys, row.path: row},
      );
      expect(handedOver.unaccepted, isEmpty);
      expect(handedOver.legacy.map((r) => r.replacement), contains(row.replacement));

      // Deregistered without a row, the same path is a boot failure — which is
      // what makes adding the row the sending story's job.
      final dropped = DartclawConfig.sweepConfigPathsForTesting(
        _yaml('agent:\n  max_turns: 40\n'),
        fields: registry,
        tolerated: ConfigMeta.toleratedLegacyKeys,
      );
      expect(dropped.unaccepted, const ['agent.max_turns']);
    });

    test('a row whose parser site still speaks is not announced twice', () {
      final config = loadYaml('automation:\n  scheduled_tasks: []\n');
      expect(
        config.warnings.where((w) => w.contains('automation.scheduled_tasks')),
        hasLength(1),
        reason: 'the parser site announces this row, so the sweep must stay quiet',
      );
      expect(
        config.warnings,
        isNot(contains(ConfigMeta.toleratedLegacyKeys['automation.scheduled_tasks']!.replacement)),
      );
    });

    test('a row whose parser site went silent is announced by the sweep instead', () {
      final config = loadYaml('guard_audit:\n  max_entries: 500\n');
      expect(config.warnings, [ConfigMeta.toleratedLegacyKeys['guard_audit.max_entries']!.replacement]);
    });

    test('a config carrying every removed key boots, and each names its replacement', () {
      const removed = {
        'automation.scheduled_tasks': 'scheduling.jobs',
        'guard_audit.max_entries': 'guard_audit.max_retention_days',
        'container.mounts': 'not mounted into agent containers',
        'container.extra_args': 'security profile',
      };

      final config = loadYaml('''
automation:
  scheduled_tasks: []
guard_audit:
  max_entries: 25000
container:
  enabled: false
  mounts:
    - /:/host:rw
  extra_args:
    - --privileged
''');

      for (final entry in removed.entries) {
        final naming = config.warnings.where((w) => w.contains(entry.value));
        expect(naming, isNotEmpty, reason: '${entry.key} names no replacement');
      }
      // The container pair also draws ContainerConfig's own unknown-key sweep;
      // two warnings for those keys is the intended signal, not a duplicate.
      expect(
        config.warnings,
        containsAll(<String>['Unknown config key: container.mounts', 'Unknown config key: container.extra_args']),
      );
      expect(config.container, const ContainerConfig(enabled: false));
      expect(config.security.guardAuditMaxRetentionDays, 30);
    });

    test('every accept-set path loads, and none of them throws', () {
      for (final path in ConfigMeta.toleratedLegacyKeys.keys) {
        final document = _yamlForPath(path);
        expect(_sweep(document).unaccepted, isEmpty, reason: path);
        expect(() => loadYaml(document), returnsNormally, reason: path);
      }
    });

    test('a deprecated key boots with a warning where a mistyped one does not', () {
      final deprecated = loadYaml('container:\n  mount_allowlist: [/tmp]\n');
      expect(deprecated.warnings, anyElement(contains('container.mount_allowlist')));

      expect(
        () => loadYaml('containr_mount_allowlist: [/tmp]\n'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains("'containr_mount_allowlist'"))),
      );
    });

    test('a deployer section survives by registering a parser, and fails loudly without one', () {
      DartclawConfig.registerExtensionParser('slack', (yaml, warns) => _Slack(yaml['webhook'] as String? ?? ''));
      expect(
        loadYaml('slack:\n  webhook: https://hooks.example.com\n').extension<_Slack>('slack').webhook,
        'https://hooks.example.com',
      );

      DartclawConfig.clearExtensionParsers();
      expect(
        () => loadYaml('slack:\n  webhook: https://hooks.example.com\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains("Unknown config field: 'slack'"), contains('registerExtensionParser')),
          ),
        ),
      );
    });

    test('the parser and the config API refuse the same path in the same words', () {
      const path = 'agent.nonexistent';
      final apiMessage = const ConfigValidator().validate(const {path: 1}).single.message;

      expect(apiMessage, unknownConfigFieldMessage(path));
      expect(
        () => loadYaml('agent:\n  nonexistent: 1\n'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(apiMessage))),
      );
    });

    test('operator-named maps and polymorphic job entries load clean', () {
      final config = loadYaml('''
mcp_servers:
  acme:
    url: https://mcp.example.com
    network_class: public
scheduling:
  jobs:
    - id: nightly
      schedule: "0 2 * * *"
      task_type: workflow
    - name: hourly
      schedule:
        every: 1h
      task_type: workflow
''');
      expect(config.scheduling.jobs, hasLength(2));
      expect(config.mcpServers.entries.keys, contains('acme'));
    });

    test('a readonly path still loads from YAML — acceptance is describability, not mutability', () {
      expect(loadYaml('guards:\n  enabled: false\n').security.guards.enabled, isFalse);
      expect(ConfigMeta.isWritable('guards.enabled'), isFalse);
    });
  });
}

class _Slack {
  final String webhook;
  const new(this.webhook);
}

ConfigPathSweep _sweep(String yaml) => DartclawConfig.sweepConfigPathsForTesting(
  _yaml(yaml),
  extensionKeys: DartclawConfig.registeredExtensionKeysForTesting(),
);

Map<Object?, Object?> _yaml(String source) => (loadYamlNode(source).value as Map).cast<Object?, Object?>();

/// A minimal document setting [path] to a scalar, nested by its segments.
String _yamlForPath(String path) {
  final segments = path.split('.');
  final buffer = StringBuffer();
  for (var depth = 0; depth < segments.length - 1; depth++) {
    buffer.writeln('${'  ' * depth}${segments[depth]}:');
  }
  buffer.writeln('${'  ' * (segments.length - 1)}${segments.last}: 1');
  return buffer.toString();
}
