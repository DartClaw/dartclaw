import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

const _baseSecurityConfig = SecurityConfig(guards: GuardConfig(enabled: true, failOpen: false));
const _baseConfig = DartclawConfig(security: _baseSecurityConfig);

/// Builds a [SecurityWiring] registered with [configNotifier] so that
/// [ConfigNotifier.reload] routes through the security seam.
SecurityWiring _buildRegisteredWiring({
  required String dataDir,
  required EventBus eventBus,
  required ConfigNotifier configNotifier,
  MessageRedactor? messageRedactor,
}) {
  return SecurityWiring(
    config: _baseConfig,
    dataDir: dataDir,
    eventBus: eventBus,
    exitFn: (code) => throw Exception('exitFn called with $code'),
    configNotifier: configNotifier,
    messageRedactor: messageRedactor,
  );
}

void main() {
  late Directory tempDir;
  late String dataDir;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sw_seam_integration_test_');
    dataDir = tempDir.path;
    eventBus = EventBus();
  });

  tearDown(() async {
    await eventBus.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Guard audit logs may be written asynchronously; ignore teardown errors.
    }
  });

  // ---------------------------------------------------------------------------
  // TI03 — Valid reload updates active protections through the security seam
  // ---------------------------------------------------------------------------

  group('security reload seam — valid reload', () {
    test('ConfigNotifier.reload with changed security config triggers SecurityWiring via watchKeys', () async {
      final configNotifier = ConfigNotifier(_baseConfig);
      final wiring = _buildRegisteredWiring(
        dataDir: dataDir,
        eventBus: eventBus,
        configNotifier: configNotifier,
      );
      await wiring.wire(agentDefs: []);

      final originalChain = wiring.guardChain!;
      final originalCount = originalChain.guards.length;

      // Add a new allowed network domain — changes the security section.
      const updatedSecurity = SecurityConfig(
        guards: GuardConfig(enabled: true, failOpen: false),
        guardsYaml: {
          'network': {
            'extra_allowed_domains': ['example.com'],
          },
        },
      );
      const updatedConfig = DartclawConfig(security: updatedSecurity);

      // Reload via ConfigNotifier — must route through SecurityWiring.reconfigure().
      final delta = configNotifier.reload(updatedConfig);

      expect(delta, isNotNull, reason: 'Security section changed, so delta should be non-null');
      expect(delta!.hasChanged('security.*'), isTrue);

      // Same chain instance — replaceGuards was called, not a new GuardChain.
      expect(wiring.guardChain, same(originalChain));
      // Guard count identical — same guard types, config updated.
      expect(wiring.guardChain!.guards.length, equals(originalCount));
    });

    test('ConfigNotifier.reload with changed security config activates new InputSanitizer extra_patterns', () async {
      final configNotifier = ConfigNotifier(_baseConfig);
      final wiring = _buildRegisteredWiring(
        dataDir: dataDir,
        eventBus: eventBus,
        configNotifier: configNotifier,
      );
      await wiring.wire(agentDefs: []);

      // Baseline: custom pattern not blocked
      final originalChain = wiring.guardChain!;
      final beforeVerdict = await originalChain.evaluateMessageReceived(
        'use the secret backdoor please',
        source: 'channel',
        sessionId: 'test-session',
        peerId: 'test-peer',
      );
      expect(beforeVerdict, isA<GuardPass>(), reason: 'Custom pattern should not block before reload');

      // Add extra input_sanitizer pattern via security reload.
      const updatedSecurity = SecurityConfig(
        guards: GuardConfig(enabled: true, failOpen: false),
        guardsYaml: {
          'input_sanitizer': {
            'extra_patterns': [r'secret\s+backdoor'],
          },
        },
      );
      const updatedConfig = DartclawConfig(security: updatedSecurity);
      configNotifier.reload(updatedConfig);

      // After reload: same chain instance, now blocks the new pattern.
      expect(wiring.guardChain, same(originalChain), reason: 'replaceGuards updates chain in-place');
      final afterVerdict = await wiring.guardChain!.evaluateMessageReceived(
        'use the secret backdoor please',
        source: 'channel',
        sessionId: 'test-session',
        peerId: 'test-peer',
      );
      expect(afterVerdict, isA<GuardBlock>(), reason: 'New extra_pattern should block after reload');
    });

    test('MessageRedactor adapter registers and recompiles on logging.* reload', () async {
      final redactor = MessageRedactor();
      final configNotifier = ConfigNotifier(_baseConfig);
      final wiring = _buildRegisteredWiring(
        dataDir: dataDir,
        eventBus: eventBus,
        configNotifier: configNotifier,
        messageRedactor: redactor,
      );
      await wiring.wire(agentDefs: []);

      const pattern = r'SECRETXYZ-\S+';
      const input = 'SECRETXYZ-abc123';

      // Before reload: not redacted.
      expect(redactor.redact(input), equals(input));

      // Update logging.redact_patterns via ConfigNotifier.
      const updatedLogging = LoggingConfig(redactPatterns: [pattern]);
      const updatedConfig = DartclawConfig(logging: updatedLogging);
      configNotifier.reload(updatedConfig);

      // After reload: redacted via _MessageRedactorAdapter.
      expect(redactor.redact(input), isNot(equals(input)));
      expect(redactor.redact(input), contains('***'));
    });
  });

  // ---------------------------------------------------------------------------
  // TI04 — Invalid reload preserves the live guard chain (fail-safe)
  // ---------------------------------------------------------------------------

  group('security reload seam — invalid reload preserves live chain', () {
    test('invalid regex in guards config via ConfigNotifier does not weaken active guard chain', () async {
      final configNotifier = ConfigNotifier(_baseConfig);
      final wiring = _buildRegisteredWiring(
        dataDir: dataDir,
        eventBus: eventBus,
        configNotifier: configNotifier,
      );
      await wiring.wire(agentDefs: []);

      final originalChain = wiring.guardChain!;
      final originalCount = originalChain.guards.length;

      // Destructive command blocked before reload.
      final before = await originalChain.evaluateBeforeToolCall(
        'shell',
        {'command': 'rm -rf /tmp/dartclaw-test'},
        sessionId: 'test-session',
      );
      expect(before, isA<GuardBlock>(), reason: 'Destructive command must be blocked before invalid reload');

      // Push an invalid security config through the notifier.
      const badSecurity = SecurityConfig(
        guards: GuardConfig(enabled: true, failOpen: false),
        guardsYaml: {
          'command': {
            'extra_blocked_patterns': ['[invalid regex here'],
          },
        },
      );
      const badConfig = DartclawConfig(security: badSecurity);
      configNotifier.reload(badConfig);

      // Chain instance unchanged — replaceGuards was NOT called.
      expect(wiring.guardChain, same(originalChain));
      expect(wiring.guardChain!.guards.length, equals(originalCount));

      // Same destructive command is still blocked — live protections preserved.
      final after = await wiring.guardChain!.evaluateBeforeToolCall(
        'shell',
        {'command': 'rm -rf /tmp/dartclaw-test'},
        sessionId: 'test-session',
      );
      expect(after, isA<GuardBlock>(), reason: 'Destructive command must still be blocked after invalid reload');
    });

    test('reload with guards.enabled=false via ConfigNotifier does not clear live chain', () async {
      final configNotifier = ConfigNotifier(_baseConfig);
      final wiring = _buildRegisteredWiring(
        dataDir: dataDir,
        eventBus: eventBus,
        configNotifier: configNotifier,
      );
      await wiring.wire(agentDefs: []);

      expect(wiring.guardChain, isNotNull);
      final originalChain = wiring.guardChain!;

      // Attempt to disable guards via ConfigNotifier — requires restart, must be ignored.
      const disabledConfig = DartclawConfig(
        security: SecurityConfig(guards: GuardConfig(enabled: false)),
      );
      configNotifier.reload(disabledConfig);

      // Chain preserved — disabling guards mid-flight requires a server restart.
      expect(wiring.guardChain, same(originalChain), reason: 'Disabling guards requires restart, chain must be preserved');

      // Active protections still block destructive commands.
      final verdict = await wiring.guardChain!.evaluateBeforeToolCall(
        'shell',
        {'command': 'rm -rf /important/data'},
        sessionId: 'test-session',
      );
      expect(verdict, isA<GuardBlock>());
    });
  });
}
