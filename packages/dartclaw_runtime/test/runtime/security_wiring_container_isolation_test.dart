import 'dart:async';
import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _ExitCalled implements Exception {
  const new(this.code);

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

  test('unavailable container isolation fails closed before any gateway wiring', () async {
    final wiring = buildWiring(container: const ContainerConfig(enabled: true), operatingSystem: 'windows');

    await expectLater(wiring.wire(agentDefs: []), throwsA(isA<_ExitCalled>().having((error) => error.code, 'code', 1)));

    final error = records.map((record) => record.error).whereType<UnsupportedCapabilityError>().single;
    expect(error.capability, 'container isolation');
    expect(error.attemptedContext, contains('container.enabled: true'));
    expect(error.remediation, allOf(contains('POSIX'), contains('WSL')));
    expect(wiring.gateway, isNull);
    expect(wiring.containersEnabled, isFalse);
    expect(wiring.availableContainerProfiles, isEmpty);
    expect(Directory(p.join(tempDir.path, 'bridge')).existsSync(), isFalse);
  });

  test('a container-enabled config declaring host mounts or Docker arguments carries neither into wiring', () async {
    // There is no longer a container config-validation step to exit at: the
    // keys reach no field, so the wiring hands ContainerManager the same
    // container config it would have got from `enabled: true` alone. What
    // follows in _wireContainers — Docker presence, image build, engine
    // architecture, bridge binary — is a runtime gate and unchanged.
    final warns = <String>[];
    final declared = ContainerConfig.fromYaml({
      'enabled': true,
      'mounts': ['/:/host:rw'],
      'extra_args': ['--privileged'],
    }, warns);

    final wiring = buildWiring(container: declared, operatingSystem: 'linux');

    expect(wiring.config.container, const ContainerConfig(enabled: true));
    expect(
      warns,
      containsAll(<String>['Unknown config key: container.mounts', 'Unknown config key: container.extra_args']),
    );
  });

  test('the advisory warning names only boundaries that are real', () async {
    final wiring = buildWiring(container: const ContainerConfig.disabled(), operatingSystem: 'linux');

    await wiring.wire(agentDefs: []);

    final warning = records.singleWhere(
      (record) => record.level == Level.WARNING && record.message.contains('Container isolation disabled'),
    );
    expect(warning.message, contains('full host access'));
    expect(warning.message, contains('Guards are the only security boundary'));
    expect(warning.message, contains('docs/guide/security.md'));
    expect(warning.message, contains('approval mode'), reason: 'the Codex bound is named rather than implied');
    // The 0.24.2 exclusion is gone: a workflow step's provider turns now run on
    // the guarded harness, so a warning that still said otherwise would send an
    // operator to compensate for something that no longer exists.
    expect(warning.message, isNot(contains('one-shot')));
    expect(warning.message, isNot(contains('allowedTools')));
  });

  test('an inferred posture with no runtime says why this host is unprotected', () async {
    final wiring = buildWiring(container: const ContainerConfig(), operatingSystem: 'linux');

    await wiring.wire(agentDefs: []);

    final warning = records.singleWhere(
      (record) => record.level == Level.WARNING && record.message.contains('Container isolation disabled'),
    );
    expect(warning.message, contains('advisory mode because no container runtime'));
    expect(warning.message, allOf(contains('docker'), contains('podman')));
    expect(warning.message, contains('docs/guide/security.md'));
  });

  test('an inferred posture whose runtime probe fails downgrades instead of exiting', () async {
    // Resolution handed wiring an enabled posture; the runtime it named is not
    // on this host, which is the mid-sequence failure S03 describes.
    final wiring = buildWiring(
      container: const ContainerConfig().resolved(enabled: true, runtimeBinary: 'dartclaw-absent-runtime'),
      operatingSystem: 'linux',
    );

    await wiring.wire(agentDefs: []);

    expect(wiring.containersEnabled, isFalse);
    final warning = records.singleWhere(
      (record) => record.level == Level.WARNING && record.message.contains('Container isolation disabled'),
    );
    expect(warning.message, contains('advisory mode because dartclaw-absent-runtime is required'));
    expect(warning.message, contains('docs/guide/security.md'));
  });

  test('the same refusal under an explicit request exits non-zero rather than downgrading', () async {
    final wiring = buildWiring(
      container: const ContainerConfig(enabled: true).resolved(enabled: true, runtimeBinary: 'dartclaw-absent-runtime'),
      operatingSystem: 'linux',
    );

    await expectLater(wiring.wire(agentDefs: []), throwsA(isA<_ExitCalled>().having((error) => error.code, 'code', 1)));

    expect(
      records.where((record) => record.level >= Level.SEVERE).map((record) => record.message),
      contains(contains('dartclaw-absent-runtime is required')),
    );
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
