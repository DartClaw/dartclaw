import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _ExitCalled implements Exception {
  const _ExitCalled(this.code);

  final int code;
}

Never _throwExit(int code) => throw _ExitCalled(code);

void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('security_wiring_isolation_test_');
    eventBus = EventBus();
    records = <LogRecord>[];
    logSubscription = Logger.root.onRecord.listen(records.add);
  });

  tearDown(() async {
    await logSubscription.cancel();
    await eventBus.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  SecurityWiring buildWiring({required ContainerConfig container, required String operatingSystem}) {
    return SecurityWiring(
      config: DartclawConfig(container: container),
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _throwExit,
      platformCapabilities: PlatformCapabilities(operatingSystem: operatingSystem),
    );
  }

  test('unavailable container isolation fails closed before credential-proxy wiring', () async {
    final wiring = buildWiring(container: const ContainerConfig(enabled: true), operatingSystem: 'windows');

    await expectLater(wiring.wire(agentDefs: []), throwsA(isA<_ExitCalled>().having((error) => error.code, 'code', 1)));

    final error = records.map((record) => record.error).whereType<UnsupportedCapabilityError>().single;
    expect(error.capability, 'container isolation');
    expect(error.attemptedContext, contains('container.enabled: true'));
    expect(error.remediation, allOf(contains('POSIX'), contains('WSL')));
    expect(wiring.credentialProxy, isNull);
    expect(wiring.containerManagers, isEmpty);
    expect(File(p.join(tempDir.path, 'proxy', 'proxy.sock')).existsSync(), isFalse);
  });

  test('available container isolation reaches the existing container validation path', () async {
    final wiring = buildWiring(
      container: const ContainerConfig(enabled: true, extraArgs: ['--privileged']),
      operatingSystem: 'linux',
    );

    await expectLater(wiring.wire(agentDefs: []), throwsA(isA<_ExitCalled>().having((error) => error.code, 'code', 1)));

    expect(records.map((record) => record.error).whereType<UnsupportedCapabilityError>(), isEmpty);
    expect(records.map((record) => record.message), contains(contains('Container config rejected')));
  });

  test('unavailable but disabled isolation wires normally with actionable host-access warning', () async {
    final wiring = buildWiring(container: const ContainerConfig.disabled(), operatingSystem: 'windows');

    await wiring.wire(agentDefs: []);

    final warning = records.singleWhere(
      (record) => record.level == Level.WARNING && record.message.contains('Container isolation disabled'),
    );
    expect(warning.message, contains('full host access'));
    expect(warning.message, contains('native Windows'));
    expect(warning.message, allOf(contains('POSIX'), contains('WSL')));
    expect(warning.message, isNot(contains('Enable container isolation')));
    expect(records.map((record) => record.error).whereType<UnsupportedCapabilityError>(), isEmpty);
    expect(records.where((record) => record.level >= Level.SEVERE), isEmpty);
  });
}
