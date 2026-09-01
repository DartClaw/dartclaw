import 'dart:io';

import 'package:dartclaw_cli/src/commands/init/setup_checks.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

SetupChecks _postWrite({
  BinaryProbeOutcome binary = BinaryProbeOutcome.responded,
  bool configParseable = true,
  bool portFree = true,
  bool providerVerified = false,
}) {
  return SetupChecks(
    loadConfig: (_) => const DartclawConfig.defaults(),
    probeBinary: (_) async => binary,
    configParseable: (_) async => configParseable,
    writeProbeFile: (_) {},
    portFree: (_) async => portFree,
    providerVerified: (_, _, _) async => providerVerified,
  );
}

const _params = (configPath: '/tmp/dartclaw.yaml', providerIds: ['claude'], instanceDir: '/tmp/.dartclaw', port: 3333);

void main() {
  group('SetupChecks pre-write stage', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('setup_checks_preflight_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('passes when all providers resolve and target path is writable', () async {
      final result = await SetupChecks(probeBinary: (_) async => BinaryProbeOutcome.responded)
          .preflight(providers: const ['claude', 'codex'], port: _freePort(), instanceDir: tempDir.path);

      expect(result.passed, isTrue);
      expect(result.errors, isEmpty);
    });

    test('fails when a provider binary returns non-zero', () async {
      final result = await SetupChecks(probeBinary: (_) async => BinaryProbeOutcome.nonZeroExit)
          .preflight(providers: const ['claude'], port: _freePort(), instanceDir: tempDir.path);

      expect(result.passed, isFalse);
      expect(result.errors.single, contains('non-zero'));
      expect(
        result.errors.single,
        isNot(contains('Install it')),
        reason: 'the binary is present — the operator must not be sent to reinstall it',
      );
    });

    test('fails when any provider binary is missing', () async {
      final result = await SetupChecks(
        probeBinary: (exe) async => exe == 'codex' ? BinaryProbeOutcome.notFound : BinaryProbeOutcome.responded,
      ).preflight(providers: const ['claude', 'codex'], port: _freePort(), instanceDir: tempDir.path);

      expect(result.passed, isFalse);
      expect(result.errors.join('\n'), contains("Provider binary 'codex'"));
      expect(result.errors.join('\n'), contains('Install it: See https://github.com/openai/codex'));
    });

    test('fails when port is already in use', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final result = await SetupChecks(probeBinary: (_) async => BinaryProbeOutcome.responded)
          .preflight(providers: const ['claude'], port: server.port, instanceDir: tempDir.path);

      expect(result.passed, isFalse);
      expect(
        result.errors.single,
        'Port ${server.port} is already in use. Choose a different port with --port or stop the existing process.',
        reason: 'the pre-write stage keeps its own message and its own remediation hint',
      );
    });

    test('workflow track skips the server port check', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final result = await SetupChecks(probeBinary: (_) async => BinaryProbeOutcome.responded)
          .preflight(providers: const ['claude'], port: server.port, instanceDir: tempDir.path, workflowTrack: true);

      expect(result.passed, isTrue);
    });

    test('accepts an instance directory whose parents do not exist yet', () async {
      // Pre-write, a not-yet-existing chain is the normal case: the probe target
      // is the nearest existing ancestor, not the requested path or its parent.
      final missing = p.join(tempDir.path, 'does-not-exist', 'nor-this', 'dartclaw');

      final result = await SetupChecks(probeBinary: (_) async => BinaryProbeOutcome.responded)
          .preflight(providers: const ['claude'], port: _freePort(), instanceDir: missing);

      expect(result.passed, isTrue, reason: 'the probe must walk up to ${tempDir.path} rather than fail on the chain');
      expect(Directory(missing).existsSync(), isFalse, reason: 'preflight checks writability, it does not create');
    });

    test('fails when instance path exists as a file', () async {
      final filePath = '${tempDir.path}/not-a-dir';
      File(filePath).writeAsStringSync('x');

      final result = await SetupChecks(probeBinary: (_) async => BinaryProbeOutcome.responded)
          .preflight(providers: const ['claude'], port: _freePort(), instanceDir: filePath);

      expect(result.passed, isFalse);
      expect(result.errors.join('\n'), contains('not a directory'));
    });
  });

  group('SetupChecks post-write stage', () {
    test('local failures block success', () async {
      final result = await _postWrite(configParseable: false).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.failed, isTrue);
      expect(result.local.failures.single, contains('valid YAML'));
    });

    test('port conflict is a blocking local failure', () async {
      final result = await _postWrite(portFree: false).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.failed, isTrue);
      expect(
        result.local.failures.single,
        'Port ${_params.port} is already in use.',
        reason: 'the post-write stage keeps its own bare message — no --port hint',
      );
    });

    test('both failing binary outcomes collapse to one message', () async {
      // The pre-write stage splits these two; post-write there is no install
      // hint to give and no config to reinstall against, so they read alike.
      for (final outcome in [BinaryProbeOutcome.nonZeroExit, BinaryProbeOutcome.notFound]) {
        final result = await _postWrite(binary: outcome).verify(
          configPath: _params.configPath,
          providerIds: _params.providerIds,
          instanceDir: _params.instanceDir,
          port: _params.port,
        );

        expect(result.failed, isTrue, reason: '$outcome must block the post-write stage');
        expect(result.local.failures.single, 'Provider binary not found in PATH: claude');
      }
    });

    test('the post-write stage probes the executable the config declares', () async {
      // Pre-write there is no config file, so the id-derived default is all
      // there is; post-write the configured executable is the divergence.
      final root = Directory.systemTemp.createTempSync('setup_checks_executable_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final configPath = p.join(root.path, 'dartclaw.yaml');
      File(configPath).writeAsStringSync(
        'data_dir: ${p.join(root.path, 'data')}\n'
        'providers:\n'
        '  claude:\n'
        '    executable: /opt/x/claude\n',
      );

      final result =
          await SetupChecks(
            probeBinary: (exe) async =>
                exe == '/opt/x/claude' ? BinaryProbeOutcome.notFound : BinaryProbeOutcome.responded,
            configParseable: (_) async => true,
            writeProbeFile: (_) {},
            portFree: (_) async => true,
            providerVerified: (_, _, _) async => true,
          ).verify(
            configPath: configPath,
            providerIds: const ['claude'],
            instanceDir: p.join(root.path, 'data'),
            port: _params.port,
          );

      expect(result.failed, isTrue);
      expect(result.local.failures.single, 'Provider binary not found in PATH: /opt/x/claude');
    });

    test('the workflow track skips the port check here too', () async {
      final result = await _postWrite(portFree: false, providerVerified: true).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
        skipPortCheck: true,
      );

      expect(result.success, isTrue);
      expect(result.local.failures, isEmpty);
    });

    test('skip-verify yields configured but unverified', () async {
      final result = await _postWrite(providerVerified: false).verify(
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
      final result = await _postWrite(providerVerified: true).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.success, isTrue);
      expect(result.outcome, VerificationOutcome.success);
    });

    test('provider verification failure yields configured but unverified', () async {
      final result = await _postWrite(providerVerified: false).verify(
        configPath: _params.configPath,
        providerIds: _params.providerIds,
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.configuredButUnverified, isTrue);
      expect(result.network?.message, contains('not verified'));
    });

    test('any unverified configured provider yields configured but unverified', () async {
      final checks = SetupChecks(
        probeBinary: (_) async => BinaryProbeOutcome.responded,
        configParseable: (_) async => true,
        writeProbeFile: (_) {},
        portFree: (_) async => true,
        providerVerified: (providerId, _, _) async => providerId == 'claude',
      );

      final result = await checks.verify(
        configPath: _params.configPath,
        providerIds: const ['claude', 'codex'],
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.configuredButUnverified, isTrue);
      expect(result.network?.message, contains('codex'));
    });

    test('the default writability probe does not walk ancestors', () async {
      // Post-write the instance directory is supposed to exist, so probing
      // further up would report a writable ancestor as if it were the instance
      // directory. Deliberately not injecting `writeProbeFile` — the default
      // primitive plus the post-write probe target is what `dartclaw init` runs.
      final root = Directory.systemTemp.createTempSync('setup_checks_writable_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final missing = p.join(root.path, 'does-not-exist', 'nor-this', 'dartclaw');

      final result =
          await SetupChecks(
            loadConfig: (_) => const DartclawConfig.defaults(),
            probeBinary: (_) async => BinaryProbeOutcome.responded,
            configParseable: (_) async => true,
            portFree: (_) async => true,
            providerVerified: (_, _, _) async => true,
          ).verify(
            configPath: _params.configPath,
            providerIds: _params.providerIds,
            instanceDir: missing,
            port: _params.port,
          );

      expect(result.failed, isTrue);
      expect(result.local.failures.single, 'Instance directory not writable: $missing');
    });

    test('verification reuses the parsed config when resolving provider binaries', () async {
      var loadCount = 0;
      final checks = SetupChecks(
        loadConfig: (_) {
          loadCount += 1;
          return const DartclawConfig.defaults();
        },
        probeBinary: (_) async => BinaryProbeOutcome.responded,
        configParseable: (_) async => true,
        writeProbeFile: (_) {},
        portFree: (_) async => true,
        providerVerified: (_, _, _) async => true,
      );

      final result = await checks.verify(
        configPath: _params.configPath,
        providerIds: const ['claude', 'codex'],
        instanceDir: _params.instanceDir,
        port: _params.port,
      );

      expect(result.success, isTrue);
      expect(loadCount, 1);
    });
  });

  group('default provider verification resolves the credential admission will', () {
    // The seam is bypassed deliberately: these prove `_defaultProviderVerified`
    // itself, which is what `dartclaw init` runs.
    late Directory root;
    late String configPath;
    late String credentialsDir;
    late String unrunnableBinary;

    setUp(() {
      root = Directory.systemTemp.createTempSync('setup_checks_verify_');
      configPath = p.join(root.path, 'dartclaw.yaml');
      credentialsDir = p.join(root.path, 'data', 'credentials');
      // Nothing here may be rescued by the vendor's own login, so the outcome
      // can only come from the credential DartClaw resolved.
      unrunnableBinary = p.join(root.path, 'no-such-claude');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    void writeConfig({String providerBody = ''}) => File(configPath).writeAsStringSync(
      'data_dir: ${p.join(root.path, 'data')}\n'
      'providers:\n'
      '  claude:\n'
      '    executable: $unrunnableBinary\n'
      '$providerBody',
    );

    Future<SetupVerificationResult> verify() => SetupChecks(
      probeBinary: (_) async => BinaryProbeOutcome.responded,
      configParseable: (_) async => true,
      writeProbeFile: (_) {},
      portFree: (_) async => true,
    ).verify(configPath: configPath, providerIds: const ['claude'], instanceDir: p.join(root.path, 'data'), port: 3333);

    test('a stored subscription token verifies without any vendor probe', () async {
      writeConfig();
      SubscriptionCredentialStore.open(
        credentialsDir: credentialsDir,
        environment: Platform.environment,
      ).storeClaudeSetupToken('sk-ant-oat01-STORED');

      final result = await verify();

      expect(result.success, isTrue, reason: 'the binary cannot run, so only the dedicated store can account for this');
    });

    test('a forced subscription selection with nothing stored is not rescued by the vendor login', () async {
      writeConfig(providerBody: '    auth: subscription\n');

      final result = await verify();

      expect(result.configuredButUnverified, isTrue);
      expect(result.network?.message, contains('claude'));
    });
  });
}

int _freePort() => 49876;
