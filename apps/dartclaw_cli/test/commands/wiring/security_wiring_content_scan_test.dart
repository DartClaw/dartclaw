import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

DartclawConfig _configWith({bool enabled = true, bool failOpen = false, int maxBytes = 50 * 1024}) => DartclawConfig(
  security: SecurityConfig(
    guards: const GuardConfig(enabled: true, failOpen: false),
    contentGuardEnabled: enabled,
    contentGuardClassifier: 'claude_binary',
    contentGuardFailOpen: failOpen,
    contentGuardMaxBytes: maxBytes,
  ),
);

void main() {
  late Directory tempDir;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sw_content_scan_test_');
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

  Future<SecurityWiring> wire(DartclawConfig config) async {
    final wiring = SecurityWiring(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: (code) => throw Exception('exitFn called with $code'),
    );
    await wiring.wire(agentDefs: const []);
    return wiring;
  }

  group('SecurityWiring.contentScan', () {
    // One instance is the whole point: if ContentGuard held its own scan, the
    // fail policy would be decided in more than one place again.
    test('is built from guards.content.* and is the instance handed to ContentGuard', () async {
      final wiring = await wire(_configWith(failOpen: true, maxBytes: 4096));

      final scan = wiring.contentScan;
      expect(scan, isNotNull);
      expect(scan!.failOpen, isTrue);
      expect(scan.maxContentBytes, 4096);
      expect(wiring.contentGuard!.scan, same(scan));
    });

    test('is null when content classification is disabled', () async {
      final wiring = await wire(_configWith(enabled: false));
      expect(wiring.contentScan, isNull);
      expect(wiring.contentGuard, isNull);
    });
  });
}
