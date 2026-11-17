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

  SecurityWiring buildWiring({
    required ContainerConfig container,
    required String operatingSystem,
    DartclawConfig? config,
    Map<String, String>? environment,
    Map<String, CredentialEntry> subscriptions = const {},
  }) {
    return SecurityWiring(
      config: (config ?? DartclawConfig()).copyWith(container: container),
      dataDir: tempDir.path,
      runtimeCwd: tempDir.path,
      eventBus: eventBus,
      exitFn: _throwExit,
      platformCapabilities: PlatformCapabilities(operatingSystem: operatingSystem),
      environment: environment,
      subscriptionCredentials: () => subscriptions,
      auditLogger: GuardAuditLogger(dataDir: tempDir.path),
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
      // A stored credential keeps the default provider off the credential
      // downgrade, so this host's own environment cannot decide the reason.
      environment: const {},
      subscriptions: const {'claude': CredentialEntry.subscription(token: 'claude-setup-token')},
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

  group('a default provider without a container credential', () {
    // The runtime named here is absent on every host, so reaching the runtime
    // refusal is the marker that wiring got past the credential check.
    final inferred = const ContainerConfig().resolved(enabled: true, runtimeBinary: 'dartclaw-absent-runtime');
    const noEnvironment = <String, String>{};
    const storedToken = {'claude': CredentialEntry.subscription(token: 'claude-setup-token')};
    const credentialAdvisory = 'has no credential a container can use';

    Iterable<String> warnings() =>
        records.where((record) => record.level == Level.WARNING).map((record) => record.message);

    test('S01: an inferred posture downgrades, naming the credential and the three ways to settle it', () async {
      final wiring = buildWiring(container: inferred, operatingSystem: 'linux', environment: noEnvironment);

      await wiring.wire(agentDefs: []);

      expect(wiring.containersEnabled, isFalse);
      final advisory = records.singleWhere(
        (record) => record.level == Level.WARNING && record.message.contains('Container isolation disabled'),
      );
      expect(
        advisory.message,
        allOf(
          contains('advisory mode because provider claude has no credential a container can use'),
          contains('claude setup-token'),
          contains('dartclaw auth claude'),
          contains('ANTHROPIC_API_KEY'),
          contains('container.enabled: false'),
          isNot(contains('dartclaw-absent-runtime')),
        ),
      );
      expect(warnings(), isNot(contains(contains('No host-held Claude credential'))));
    });

    test('the credential downgrade still reclaims containers an earlier serve left behind', () async {
      // A stand-in container CLI that answers the version probe, lists one owned
      // orphan and records every verb it is asked to run.
      final calls = File(p.join(tempDir.path, 'runtime-calls.log'));
      final runtime = File(p.join(tempDir.path, 'fake-runtime'))
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$@" >> "${calls.path}"\ncase "\$1" in\n  ps) echo dartclaw-orphan ;;\nesac\nexit 0\n',
        );
      Process.runSync('chmod', ['+x', runtime.path]);
      final wiring = buildWiring(
        container: const ContainerConfig().resolved(enabled: true, runtimeBinary: runtime.path),
        operatingSystem: 'linux',
        environment: noEnvironment,
      );

      await wiring.wire(agentDefs: []);

      expect(wiring.containersEnabled, isFalse);
      expect(warnings(), contains(contains(credentialAdvisory)));
      expect(calls.readAsLinesSync(), contains('rm -f dartclaw-orphan'));
    });

    test('an absent runtime on the credential downgrade attempts no sweep', () async {
      final wiring = buildWiring(container: inferred, operatingSystem: 'linux', environment: noEnvironment);

      await wiring.wire(agentDefs: []);

      expect(warnings(), isNot(contains(contains('Failed to sweep owned containers'))));
    });

    test('S02: a stored setup-token keeps containers on the path to the runtime probe', () async {
      final wiring = buildWiring(
        container: inferred,
        operatingSystem: 'linux',
        environment: noEnvironment,
        subscriptions: storedToken,
      );

      await wiring.wire(agentDefs: []);

      expect(
        records.singleWhere((r) => r.level == Level.WARNING && r.message.contains('Container isolation disabled')),
        isA<LogRecord>().having((r) => r.message, 'message', contains('because dartclaw-absent-runtime is required')),
      );
      expect(warnings(), isNot(contains(contains(credentialAdvisory))));
    });

    test('S03: an explicit request is not downgraded for the credential', () async {
      final wiring = buildWiring(
        container: const ContainerConfig(enabled: true)
            .resolved(enabled: true, runtimeBinary: 'dartclaw-absent-runtime'),
        operatingSystem: 'linux',
        environment: noEnvironment,
      );

      await expectLater(
        wiring.wire(agentDefs: []),
        throwsA(isA<_ExitCalled>().having((error) => error.code, 'code', 1)),
      );

      expect(
        records.where((record) => record.level >= Level.SEVERE).map((record) => record.message),
        contains(contains('dartclaw-absent-runtime is required')),
      );
      expect(warnings(), isNot(contains(contains(credentialAdvisory))));
    });

    test('S04: a secondary provider without a credential does not downgrade the deployment', () async {
      final wiring = buildWiring(
        container: inferred,
        operatingSystem: 'linux',
        environment: noEnvironment,
        subscriptions: storedToken,
        config: DartclawConfig(
          providers: ProvidersConfig(
            entries: {
              'claude': const ProviderEntry(executable: 'claude'),
              'codex': const ProviderEntry(executable: 'codex'),
            },
          ),
        ),
      );

      await wiring.wire(agentDefs: []);

      expect(warnings(), contains(contains('because dartclaw-absent-runtime is required')));
      expect(warnings(), isNot(contains(contains(credentialAdvisory))));
    });

    test('S05: a primary pinned to the host needs no container credential', () async {
      final wiring = buildWiring(
        container: inferred,
        operatingSystem: 'linux',
        environment: noEnvironment,
        config: DartclawConfig(agent: const AgentConfig(execution: ExecutionMode.host)),
      );

      await wiring.wire(agentDefs: []);

      expect(warnings(), contains(contains('because dartclaw-absent-runtime is required')));
      expect(warnings(), isNot(contains(contains(credentialAdvisory))));
    });
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
