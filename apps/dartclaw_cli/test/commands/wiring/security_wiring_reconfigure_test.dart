import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

const _enabledSecurity = SecurityConfig(guards: GuardConfig(enabled: true, failOpen: false));
const _baseConfig = DartclawConfig(security: _enabledSecurity);

ConfigDelta _delta(DartclawConfig previous, DartclawConfig current) {
  return ConfigDelta(previous: previous, current: current, changedKeys: const {'guards.*'});
}

void main() {
  late Directory tempDir;
  late String dataDir;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sw_reconfig_test_');
    dataDir = tempDir.path;
    eventBus = EventBus();
  });

  tearDown(() async {
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  SecurityWiring buildWiring(DartclawConfig config, {ConfigNotifier? configNotifier}) {
    return SecurityWiring(
      config: config,
      dataDir: dataDir,
      eventBus: eventBus,
      exitFn: (code) => throw Exception('exitFn called with $code'),
      configNotifier: configNotifier,
    );
  }

  group('SecurityWiring.reconfigure()', () {
    test('valid changed guards config rebuilds guard chain via replaceGuards', () async {
      final wiring = buildWiring(_baseConfig);
      await wiring.wire(agentDefs: []);

      final originalChain = wiring.guardChain!;
      final originalCount = originalChain.guards.length;

      const newSecurity = SecurityConfig(
        guards: GuardConfig(enabled: true, failOpen: false),
        guardsYaml: {
          'network': {
            'extra_allowed_domains': ['example.com'],
          },
        },
      );
      const newConfig = DartclawConfig(security: newSecurity);
      final delta = _delta(_baseConfig, newConfig);

      wiring.reconfigure(delta);

      // Same chain instance — replaceGuards called, not new GuardChain.
      expect(wiring.guardChain, same(originalChain));
      // Same guard count (same guard types, config just updated).
      expect(wiring.guardChain!.guards.length, equals(originalCount));
    });

    test('invalid config (bad regex) preserves existing guard chain', () async {
      final wiring = buildWiring(_baseConfig);
      await wiring.wire(agentDefs: []);

      final originalChain = wiring.guardChain!;
      final originalCount = originalChain.guards.length;

      const badSecurity = SecurityConfig(
        guards: GuardConfig(enabled: true, failOpen: false),
        guardsYaml: {
          'command': {
            'extra_blocked_patterns': ['[invalid regex here'],
          },
        },
      );
      const newConfig = DartclawConfig(security: badSecurity);
      final delta = _delta(_baseConfig, newConfig);

      // Must not throw.
      expect(() => wiring.reconfigure(delta), returnsNormally);

      // Guard count unchanged — original chain preserved.
      expect(wiring.guardChain!.guards.length, equals(originalCount));
    });

    test('invalid config does not partially mutate the live InputSanitizer', () async {
      final wiring = buildWiring(_baseConfig);
      await wiring.wire(agentDefs: []);

      final originalSanitizer = wiring.guardChain!.guards.whereType<InputSanitizer>().first;
      final originalPatterns = originalSanitizer.config.patterns.length;

      const badSecurity = SecurityConfig(
        guards: GuardConfig(enabled: true, failOpen: false),
        guardsYaml: {
          'input_sanitizer': {
            'extra_patterns': [r'secret\s+backdoor'],
          },
          'network': {
            'extra_exfil_patterns': ['[invalid regex here'],
          },
        },
      );
      const newConfig = DartclawConfig(security: badSecurity);

      wiring.reconfigure(_delta(_baseConfig, newConfig));

      final currentSanitizer = wiring.guardChain!.guards.whereType<InputSanitizer>().first;
      expect(currentSanitizer, same(originalSanitizer));
      expect(currentSanitizer.config.patterns.length, equals(originalPatterns));
      expect(currentSanitizer.config.patterns.any((entry) => entry.pattern.pattern == r'secret\s+backdoor'), isFalse);
    });

    test('guards.enabled=false in new config — logs warning, chain NOT cleared', () async {
      final wiring = buildWiring(_baseConfig);
      await wiring.wire(agentDefs: []);

      expect(wiring.guardChain, isNotNull);

      const disabledConfig = DartclawConfig(security: SecurityConfig(guards: GuardConfig(enabled: false)));
      final delta = _delta(_baseConfig, disabledConfig);

      // Must not throw, must not clear the chain (requires restart).
      wiring.reconfigure(delta);

      expect(
        wiring.guardChain,
        isNotNull,
        reason: 'Disabling guards mid-flight requires restart — chain must be preserved',
      );
    });

    test('reconfigure() when guard chain is null (guards disabled at startup) — no-ops safely', () async {
      const disabledBase = DartclawConfig(security: SecurityConfig(guards: GuardConfig(enabled: false)));
      final wiring = buildWiring(disabledBase);
      await wiring.wire(agentDefs: []);

      expect(wiring.guardChain, isNull);

      const newConfig = DartclawConfig(security: _enabledSecurity);
      final delta = _delta(disabledBase, newConfig);

      // Should not throw.
      expect(() => wiring.reconfigure(delta), returnsNormally);
      // Still null — enabling guards mid-flight not supported.
      expect(wiring.guardChain, isNull);
    });
  });
}
