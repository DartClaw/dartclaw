import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_cli/src/commands/service/setup_verifier.dart';
import 'package:test/test.dart';

SetupVerifier _verifier({
  bool binaryExists = true,
  bool configParseable = true,
  bool dirWritable = true,
  bool portFree = true,
  bool providerVerified = false,
}) {
  return SetupVerifier(
    binaryExists: (_) async => binaryExists,
    configParseable: (_) async => configParseable,
    dirWritable: (_) async => dirWritable,
    portFree: (_) async => portFree,
    providerVerified: (_, _, _) async => providerVerified,
  );
}

const _params = (configPath: '/tmp/dartclaw.yaml', providerIds: ['claude'], instanceDir: '/tmp/.dartclaw', port: 3333);

void main() {
  group('SetupVerifier', () {
    test('local failures block success', () async {
      final result = await _verifier(configParseable: false).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.failed, isTrue);
      expect(result.local.failures.single, contains('valid YAML'));
    });

    test('port conflict is a blocking local failure', () async {
      final result = await _verifier(portFree: false).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.failed, isTrue);
      expect(result.local.failures.single, contains('already in use'));
    });

    test('skip-verify yields configured but unverified', () async {
      final result = await _verifier(providerVerified: false).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
        skipNetwork: true,
      );

      expect(result.configuredButUnverified, isTrue);
      expect(result.network?.skipped, isTrue);
    });

    test('provider verification success yields verified outcome', () async {
      final result = await _verifier(providerVerified: true).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.success, isTrue);
      expect(result.outcome, VerificationOutcome.success);
    });

    test('provider verification failure yields configured but unverified', () async {
      final result = await _verifier(providerVerified: false).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.configuredButUnverified, isTrue);
      expect(result.network?.message, contains('not verified'));
    });

    test('any unverified configured provider yields configured but unverified', () async {
      final verifier = SetupVerifier(
        binaryExists: (_) async => true,
        configParseable: (_) async => true,
        dirWritable: (_) async => true,
        portFree: (_) async => true,
        providerVerified: (providerId, _, _) async => providerId == 'claude',
      );

      final result = await verifier.verify(
        configPath: _params.configPath,
        providerIds: const ['claude', 'codex'],
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.configuredButUnverified, isTrue);
      expect(result.network?.message, contains('codex'));
    });

    test('verification reuses the parsed config when resolving provider binaries', () async {
      var loadCount = 0;
      final verifier = SetupVerifier(
        loadConfig: (_) {
          loadCount += 1;
          return const DartclawConfig.defaults();
        },
        binaryExists: (_) async => true,
        configParseable: (_) async => true,
        dirWritable: (_) async => true,
        portFree: (_) async => true,
        providerVerified: (_, _, _) async => true,
      );

      final result = await verifier.verify(
        configPath: _params.configPath,
        providerIds: const ['claude', 'codex'],
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.success, isTrue);
      expect(loadCount, 1);
    });
  });
}
