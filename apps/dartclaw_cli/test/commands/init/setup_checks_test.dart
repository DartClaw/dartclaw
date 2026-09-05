import 'dart:io';

import 'package:dartclaw_cli/src/commands/init/setup_checks.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/secrets/credential_inventory.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
import 'package:yaml/yaml.dart' show loadYaml;
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
    probeBinary: (_) async => (outcome: binary, version: null),
    configParseable: (_) async => configParseable,
    writeProbeFile: (_) {},
    portFree: (_) async => portFree,
    providerVerified: (_, _, _) async => providerVerified,
  );
}

const _params = (configPath: '/tmp/dartclaw.yaml', providerIds: ['claude'], instanceDir: '/tmp/.dartclaw', port: 3333);

void main() {
  group('diagnose:', () {
    late Directory root;
    late File config;
    late String dataDir;
    late Map<String, String> environment;

    setUp(() {
      root = Directory.systemTemp.createTempSync('doctor_checks_');
      dataDir = p.join(root.path, 'data');
      config = File(p.join(root.path, 'dartclaw.yaml'));
      environment = {'HOME': p.join(root.path, 'home'), 'PATH': ''};
      for (final child in ['workspace', 'sessions', 'logs']) {
        Directory(p.join(dataDir, child)).createSync(recursive: true);
      }
    });
    tearDown(() {
      DartclawConfig.clearStoredCredentialProvider();
      root.deleteSync(recursive: true);
    });

    void writeConfig([String extra = '']) {
      config.writeAsStringSync('data_dir: $dataDir\nproviders:\n  claude:\n    executable: my-claude\n$extra');
      if (!Platform.isWindows) Process.runSync('chmod', ['600', config.path]);
    }

    Future<DiagnosticReport> diagnose({
      bool free = true,
      Map<String, dynamic>? health,
      String? serverOverride,
      String? runtimeCase,
      bool windows = false,
      String? resolvedExecutable,
      List<List<String>>? commands,
      bool realCredentials = false,
    }) async {
      final checks = SetupChecks(
        probeBinary: (binary) async => (
          outcome: binary == 'missing-codex' ? BinaryProbeOutcome.notFound : BinaryProbeOutcome.responded,
          version: '2.1.80',
        ),
        portFree: (_) async => free,
        writeProbeFile: (_) {},
        providerVerified: realCredentials ? null : (_, _, _) async => true,
        serverHealth: (_, _) async => health,
        resolvedExecutable: resolvedExecutable,
        runCommand: (binary, args) async {
          commands?.add(args);
          if (runtimeCase == null) return ProcessResult(1, 1, '', '');
          if (args.first == 'ps') {
            return ProcessResult(
              1,
              runtimeCase == 'query-error' ? 1 : 0,
              runtimeCase == 'orphans' ? 'dartclaw-one\ndartclaw-two\n' : '',
              '',
            );
          }
          if (args.first == 'image') return ProcessResult(1, runtimeCase == 'image' ? 1 : 0, '', '');
          return ProcessResult(1, 0, runtimeCase == 'engine' ? 's390x' : 'amd64', '');
        },
      );
      return checks.diagnose(
        configPath: config.path,
        serverOverride: serverOverride,
        environment: environment,
        platformCapabilities: PlatformCapabilities(
          operatingSystem: windows ? 'windows' : 'linux',
          environment: environment,
        ),
      );
    }

    DiagnosticRow row(DiagnosticReport report, String id) => report.rows.singleWhere((row) => row.id == id);

    test('S02 S03 server health distinguishes DartClaw from a port conflict', () async {
      writeConfig();
      final stopped = await diagnose();
      final running = await diagnose(free: false, health: {'status': 'ok', 'version': dartclawVersion, 'uptime_s': 42});
      expect(row(running, 'server.health').status, DiagnosticStatus.pass);
      expect(row(running, 'server.health').summary, allOf(contains(dartclawVersion), contains('42')));
      expect(running.rows.map((r) => r.id), isNot(contains('server.port')));
      expect(
        running.rows.where((r) => !r.id.startsWith('server.')).map((r) => r.toJson()),
        stopped.rows.where((r) => !r.id.startsWith('server.')).map((r) => r.toJson()),
      );
      final conflict = await diagnose(free: false);
      expect(row(conflict, 'server.port').status, DiagnosticStatus.fail);
      expect(
        row(conflict, 'server.port').remediation,
        'Choose a different port with --port or stop the existing process.',
      );
      final remote = await diagnose(serverOverride: 'https://remote.example');
      expect(row(remote, 'server.health').status, DiagnosticStatus.fail);
      expect(remote.rows.map((r) => r.id), isNot(contains('server.port')));
      final mismatch = await diagnose(free: false, health: {'status': 'ok', 'version': 'old', 'uptime_s': 42});
      expect(row(mismatch, 'server.health').status, DiagnosticStatus.warn);
    });

    test('S04 fatal configs skip dependents and loadable invalid values retain loader messages', () async {
      for (final content in <String?>[null, 'agent: [']) {
        if (content != null) config.writeAsStringSync(content);
        final report = await diagnose();
        expect(row(report, 'config.parse').status, DiagnosticStatus.fail);
        expect(
          report.rows.where((r) => r.id != 'config.parse').every((r) => r.status == DiagnosticStatus.skip),
          isTrue,
        );
      }
      writeConfig('made_up_field: true\n');
      final rejected = await diagnose();
      expect(row(rejected, 'config.valid').status, DiagnosticStatus.fail);
      expect(row(rejected, 'config.valid').summary, contains('made_up_field'));
      expect(
        rejected.rows.where((r) => !r.id.startsWith('config.')).every((r) => r.status == DiagnosticStatus.skip),
        isTrue,
      );
      writeConfig('    auth: nonsense\n');
      final declared = loadCliConfig(configPath: config.path, env: environment, resolveStoredCredentials: false);
      final report = await diagnose();
      expect(declared.reloadBlockingWarnings, isNotEmpty);
      expect(
        report.rows.where((r) => r.id == 'config.valid' && r.status == DiagnosticStatus.fail).map((r) => r.summary),
        declared.reloadBlockingWarnings,
      );
    });

    test('S05 configured binaries retain versions and missing binaries skip credentials', () async {
      writeConfig();
      config.writeAsStringSync('  codex:\n    executable: missing-codex\n', mode: FileMode.append);
      final report = await diagnose();
      expect(row(report, 'provider.claude.binary').summary, contains('2.1.80'));
      expect(row(report, 'provider.codex.binary').summary, 'Provider binary not found in PATH: missing-codex');
      expect(row(report, 'provider.codex.credential').status, DiagnosticStatus.skip);
      final unverified = await diagnose(realCredentials: true);
      expect(row(unverified, 'provider.claude.credential').status, DiagnosticStatus.fail);
      expect(
        row(unverified, 'provider.claude.credential').remediation,
        allOf(contains('dartclaw auth claude'), contains('dartclaw secrets set')),
      );
    });

    test('S06 storage rows reuse audit findings without printing values', () async {
      writeConfig(r'''credentials:
  brave:
    type: api-key
    api_key: LITERAL-DOCTOR-SECRET
  missing:
    type: api-key
    api_key: ${DOCTOR_MISSING}
search:
  providers:
    brave:
      credential: brave
mcp_servers:
  missing:
    command: no-command
    network_class: local
    credential: missing
''');
      if (!Platform.isWindows) Process.runSync('chmod', ['644', config.path]);
      final declared = loadCliConfig(configPath: config.path, env: environment, resolveStoredCredentials: false);
      final audit = auditSecrets(
        config: declared,
        yaml: Map<String, dynamic>.from(loadYaml(config.readAsStringSync()) as Map),
        stored: {},
        configPath: config.path,
        environment: environment,
      );
      final report = await diagnose();
      expect(
        row(report, 'secrets.literals').detail,
        audit['Literals in config']!.map((f) => '${f.path}: ${f.reason}').toList(),
      );
      expect(row(report, 'secrets.unresolvable').status, DiagnosticStatus.fail);
      expect(row(report, 'secrets.shadowed').status, DiagnosticStatus.pass);
      expect(row(report, 'secrets.orphans').status, DiagnosticStatus.pass);
      if (!Platform.isWindows) expect(row(report, 'secrets.permissions').status, DiagnosticStatus.fail);
      expect(report.rows.map((r) => r.toJson()).toString(), isNot(contains('LITERAL-DOCTOR-SECRET')));
    });

    test('S07 runtime, image and engine failures follow declared posture without building', () async {
      for (final declared in [false, true]) {
        for (final failure in <String?>[null, 'image', 'engine']) {
          writeConfig(declared ? 'container:\n  enabled: true\n' : '');
          final commands = <List<String>>[];
          final report = await diagnose(runtimeCase: failure, commands: commands);
          expect(
            row(report, 'container.${failure ?? 'runtime'}').status,
            declared ? DiagnosticStatus.fail : DiagnosticStatus.warn,
          );
          expect(commands.any((args) => args.first == 'build'), isFalse);
        }
      }
      writeConfig();
      expect(row(await diagnose(windows: true), 'container.runtime').status, DiagnosticStatus.skip);
      writeConfig('container:\n  enabled: true\n');
      final declaredWindows = row(await diagnose(windows: true), 'container.runtime');
      expect(declaredWindows.status, DiagnosticStatus.fail);
      expect(declaredWindows.summary, contains('native Windows'));
    });

    test('S10 Windows checks share Git Bash resolution and distinguish source/release layouts', () async {
      writeConfig('gateway:\n  reload:\n    mode: signal\n');
      final executable = p.join(root.path, 'bin', 'dartclaw.exe');
      final source = await diagnose(windows: true, resolvedExecutable: executable);
      expect(row(source, 'windows.sqlite_dll').status, DiagnosticStatus.skip);
      Directory(p.join(root.path, 'lib')).createSync();
      final report = await diagnose(windows: true, resolvedExecutable: executable);
      expect(row(report, 'windows.sqlite_dll').status, DiagnosticStatus.fail);
      expect(row(report, 'windows.reload_mode').status, DiagnosticStatus.warn);
      expect(row(report, 'windows.reload_mode').remediation, contains('auto'));
      expect(row(report, 'windows.git_bash').remediation, contains('bash steps require Git Bash on Windows'));
      expect(row(report, 'secrets.permissions').status, DiagnosticStatus.skip);
      File(p.join(root.path, 'lib', 'sqlite3.dll')).writeAsStringSync('');
      expect(
        row(await diagnose(windows: true, resolvedExecutable: executable), 'windows.sqlite_dll').status,
        DiagnosticStatus.pass,
      );
      expect((await diagnose()).rows.any((r) => r.id.startsWith('windows.')), isFalse);
    });

    test('DR03 health uses the public endpoint without credentials and rejects malformed peers', () async {
      writeConfig('gateway:\n  auth_mode: token\n  token: GATEWAY-SECRET\n');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? authorization;
      var valid = true;
      server.listen((request) async {
        authorization = request.headers.value('authorization');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          valid ? '{"status":"ok","version":"$dartclawVersion","uptime_s":42}' : '{"other":"service"}',
        );
        await request.response.close();
      });
      final checks = SetupChecks(
        probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null),
        portFree: (_) async => false,
        writeProbeFile: (_) {},
        providerVerified: (_, _, _) async => true,
        runCommand: (_, _) async => ProcessResult(1, 1, '', ''),
      );
      Future<DiagnosticReport> run() => checks.diagnose(
        configPath: config.path,
        environment: environment,
        serverOverride: 'http://127.0.0.1:${server.port}',
      );
      expect(row(await run(), 'server.health').status, DiagnosticStatus.pass);
      expect(authorization, isNull);
      valid = false;
      expect(row(await run(), 'server.health').status, DiagnosticStatus.fail);
    });

    test('DR03 missing or malformed status cannot mask a port conflict or suppress orphan queries', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      writeConfig('port: ${server.port}\n');
      var includeMalformed = false;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{${includeMalformed ? '"status":42,' : ''}"version":"$dartclawVersion","uptime_s":42}');
        await request.response.close();
      });
      final checks = SetupChecks(
        probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null),
        portFree: (_) async => false,
        writeProbeFile: (_) {},
        providerVerified: (_, _, _) async => true,
        runCommand: (_, args) async => ProcessResult(0, 0, args.first == 'ps' ? 'dartclaw-orphan' : 'amd64', ''),
      );
      for (final malformed in [false, true]) {
        includeMalformed = malformed;
        final report = await checks.diagnose(configPath: config.path, environment: environment);
        expect(row(report, 'server.port').status, DiagnosticStatus.fail);
        expect(report.server, isNull);
        expect(row(report, 'container.orphans').status, DiagnosticStatus.warn);
        expect(row(report, 'container.orphans').detail, ['dartclaw-orphan']);
      }
    });

    test('S12 orphan containers are reported only, with query failures advisory', () async {
      writeConfig();
      final commands = <List<String>>[];
      final report = await diagnose(runtimeCase: 'orphans', commands: commands);
      expect(row(report, 'container.orphans').status, DiagnosticStatus.warn);
      expect(row(report, 'container.orphans').detail, ['dartclaw-one', 'dartclaw-two']);
      expect(row(report, 'container.orphans').remediation, contains('reclaimed at the next `dartclaw serve` start'));
      expect(row(await diagnose(runtimeCase: 'empty'), 'container.orphans').status, DiagnosticStatus.pass);
      expect(row(await diagnose(runtimeCase: 'query-error'), 'container.orphans').status, DiagnosticStatus.warn);
      expect(
        row(
          await diagnose(
            runtimeCase: 'orphans',
            free: false,
            health: {'status': 'ok', 'version': dartclawVersion, 'uptime_s': 42},
          ),
          'container.orphans',
        ).status,
        DiagnosticStatus.skip,
      );
      expect(commands.any((args) => args.first == 'rm'), isFalse);
      expect((await diagnose()).rows.any((r) => r.id == 'container.orphans'), isFalse);
    });
  });

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
      final result = await SetupChecks(probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null))
          .preflight(providers: const ['claude', 'codex'], port: _freePort(), instanceDir: tempDir.path);

      expect(result.passed, isTrue);
      expect(result.errors, isEmpty);
    });

    test('fails when a provider binary returns non-zero', () async {
      final result = await SetupChecks(
        probeBinary: (_) async => (outcome: BinaryProbeOutcome.nonZeroExit, version: null),
      ).preflight(providers: const ['claude'], port: _freePort(), instanceDir: tempDir.path);

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
        probeBinary: (exe) async =>
            (outcome: exe == 'codex' ? BinaryProbeOutcome.notFound : BinaryProbeOutcome.responded, version: null),
      ).preflight(providers: const ['claude', 'codex'], port: _freePort(), instanceDir: tempDir.path);

      expect(result.passed, isFalse);
      expect(result.errors.join('\n'), contains("Provider binary 'codex'"));
      expect(result.errors.join('\n'), contains('Install it: See https://github.com/openai/codex'));
    });

    test('fails when port is already in use', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final result = await SetupChecks(probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null))
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

      final result = await SetupChecks(probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null))
          .preflight(providers: const ['claude'], port: server.port, instanceDir: tempDir.path, workflowTrack: true);

      expect(result.passed, isTrue);
    });

    test('accepts an instance directory whose parents do not exist yet', () async {
      // Pre-write, a not-yet-existing chain is the normal case: the probe target
      // is the nearest existing ancestor, not the requested path or its parent.
      final missing = p.join(tempDir.path, 'does-not-exist', 'nor-this', 'dartclaw');

      final result = await SetupChecks(probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null))
          .preflight(providers: const ['claude'], port: _freePort(), instanceDir: missing);

      expect(result.passed, isTrue, reason: 'the probe must walk up to ${tempDir.path} rather than fail on the chain');
      expect(Directory(missing).existsSync(), isFalse, reason: 'preflight checks writability, it does not create');
    });

    test('fails when instance path exists as a file', () async {
      final filePath = '${tempDir.path}/not-a-dir';
      File(filePath).writeAsStringSync('x');

      final result = await SetupChecks(probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null))
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
            probeBinary: (exe) async => (
              outcome: exe == '/opt/x/claude' ? BinaryProbeOutcome.notFound : BinaryProbeOutcome.responded,
              version: null,
            ),
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

    test('the post-write stage probes the claude executable the server config names', () async {
      // `server.claude_executable` is the runtime's family default for a
      // claude-family provider declaring no executable of its own, so probing
      // the id-derived `claude` here checks a binary no spawn lane would run.
      final root = Directory.systemTemp.createTempSync('setup_checks_server_executable_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final configPath = p.join(root.path, 'dartclaw.yaml');
      File(configPath).writeAsStringSync('data_dir: ${p.join(root.path, 'data')}\n');
      final probed = <String>[];

      final result =
          await SetupChecks(
            loadConfig: (path) =>
                loadCliConfig(configPath: path, cliOverrides: const {'claude_executable': '/custom/claude'}),
            probeBinary: (executable) async {
              probed.add(executable);
              return (outcome: BinaryProbeOutcome.responded, version: null);
            },
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

      expect(probed, ['/custom/claude']);
      expect(result.failed, isFalse);
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
        probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null),
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
            probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null),
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
        probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null),
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
      probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: null),
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
