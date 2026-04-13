import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'helpers/probe_helpers.dart';

void main() {
  late Directory tempDir;
  late MessageService messages;
  late List<HarnessPool> pools;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('provider_status_service_test_');
    messages = MessageService(baseDir: tempDir.path);
    pools = <HarnessPool>[];
  });

  tearDown(() async {
    for (final pool in pools) {
      await pool.dispose();
    }
    await messages.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ProviderStatusService', () {
    test('falls back to a single legacy claude provider and marks it as default', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig.defaults(),
        registry: _registry(anthropicApiKey: 'anthropic-key'),
        defaultProvider: 'claude',
        pool: _buildPool(
          pools: pools,
          messages: messages,
          workspaceDir: tempDir.path,
          runners: const [
            (providerId: 'claude', state: WorkerState.idle),
            (providerId: 'claude', state: WorkerState.busy),
            (providerId: 'claude', state: WorkerState.idle),
          ],
        ),
      );

      await service.probe(commandProbe: probeResults({'claude': probeOk('Claude CLI 1.0.0')}));

      final statuses = service.getAll();
      expect(statuses, hasLength(1));

      final status = statuses.single;
      expect(status.id, 'claude');
      expect(status.executable, 'claude');
      expect(status.version, 'Claude CLI 1.0.0');
      expect(status.binaryFound, isTrue);
      expect(status.credentialStatus, 'present');
      expect(status.credentialEnvVar, 'ANTHROPIC_API_KEY');
      expect(status.poolSize, 2);
      expect(status.activeWorkers, 1);
      expect(status.isDefault, isTrue);
      expect(status.health, 'healthy');
      expect(status.errorMessage, isNull);
      expect(service.getSummary(), {'configured': 1, 'healthy': 1, 'degraded': 0});
    });

    test('falls back to a single legacy codex provider and uses codex pool runners', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig.defaults(),
        registry: _registry(openAiApiKey: 'openai-key'),
        defaultProvider: 'codex',
        pool: _buildPool(
          pools: pools,
          messages: messages,
          workspaceDir: tempDir.path,
          runners: const [
            (providerId: 'codex', state: WorkerState.idle),
            (providerId: 'codex', state: WorkerState.busy),
            (providerId: 'codex', state: WorkerState.idle),
          ],
        ),
      );

      await service.probe(commandProbe: probeResults({'codex': probeOk('Codex CLI 0.9.0')}));

      final statuses = service.getAll();
      expect(statuses, hasLength(1));

      final status = statuses.single;
      expect(status.id, 'codex');
      expect(status.executable, 'codex');
      expect(status.version, 'Codex CLI 0.9.0');
      expect(status.binaryFound, isTrue);
      expect(status.credentialStatus, 'present');
      expect(status.credentialEnvVar, 'OPENAI_API_KEY');
      expect(status.poolSize, 2);
      expect(status.activeWorkers, 1);
      expect(status.isDefault, isTrue);
      expect(status.health, 'healthy');
      expect(status.errorMessage, isNull);
      expect(service.getSummary(), {'configured': 1, 'healthy': 1, 'degraded': 0});
    });

    test('treats codex-exec as a codex-family provider for executable and credentials', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig.defaults(),
        registry: _registry(openAiApiKey: 'openai-key'),
        defaultProvider: 'codex-exec',
        pool: _buildPool(
          pools: pools,
          messages: messages,
          workspaceDir: tempDir.path,
          runners: const [
            (providerId: 'codex-exec', state: WorkerState.idle),
            (providerId: 'codex-exec', state: WorkerState.busy),
            (providerId: 'codex-exec', state: WorkerState.idle),
          ],
        ),
      );

      await service.probe(commandProbe: probeResults({'codex': probeOk('Codex CLI 1.2.3')}));

      final status = service.getAll().single;
      expect(status.id, 'codex-exec');
      expect(status.executable, 'codex');
      expect(status.version, 'Codex CLI 1.2.3');
      expect(status.credentialEnvVar, 'CODEX_API_KEY');
      expect(status.activeWorkers, 1);
      expect(status.isDefault, isTrue);
    });

    test('reports multiple configured providers with healthy, degraded, and unavailable states', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: 'claude', poolSize: 3),
            'codex': ProviderEntry(executable: 'codex', poolSize: 2),
            'ghost': ProviderEntry(executable: 'ghost', poolSize: 1),
          },
        ),
        registry: _registry(anthropicApiKey: 'anthropic-key'),
        defaultProvider: 'claude',
        pool: _buildPool(
          pools: pools,
          messages: messages,
          workspaceDir: tempDir.path,
          runners: const [
            (providerId: 'claude', state: WorkerState.idle),
            (providerId: 'claude', state: WorkerState.busy),
            (providerId: 'codex', state: WorkerState.idle),
            (providerId: 'ghost', state: WorkerState.busy),
          ],
        ),
      );

      await service.probe(
        commandProbe: probeResults({
          'claude': probeOk('Claude CLI 2.1.0'),
          'codex': probeOk('Codex CLI 0.8.0'),
          'ghost': probeMissing('ghost'),
        }),
        authProbe: _authFails,
      );

      final statuses = {for (final status in service.getAll()) status.id: status};
      expect(statuses.keys, containsAll(<String>['claude', 'codex', 'ghost']));

      final claude = statuses['claude']!;
      expect(claude.toJson(), {
        'id': 'claude',
        'executable': 'claude',
        'version': 'Claude CLI 2.1.0',
        'binaryFound': true,
        'credentialStatus': 'present',
        'credentialEnvVar': 'ANTHROPIC_API_KEY',
        'poolSize': 3,
        'activeWorkers': 1,
        'isDefault': true,
        'health': 'healthy',
        'errorMessage': null,
      });

      final codex = statuses['codex']!;
      expect(codex.health, 'degraded');
      expect(codex.credentialStatus, 'missing');
      expect(codex.credentialEnvVar, 'OPENAI_API_KEY');
      expect(codex.binaryFound, isTrue);
      expect(codex.errorMessage, contains("Credentials missing for provider 'codex'"));
      expect(codex.errorMessage, contains('OPENAI_API_KEY'));
      expect(codex.errorMessage, contains('credentials section'));

      final ghost = statuses['ghost']!;
      expect(ghost.health, 'unavailable');
      expect(ghost.binaryFound, isFalse);
      expect(ghost.errorMessage, contains("Binary 'ghost' for provider 'ghost' was not found."));
      expect(ghost.errorMessage, contains('providers.ghost.executable'));
      expect(service.getSummary(), {'configured': 3, 'healthy': 1, 'degraded': 1});
    });

    test('reports OAuth-authenticated provider as healthy with oauth credential status', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 2)}),
        registry: _registry(),
        defaultProvider: 'claude',
      );

      await service.probe(
        commandProbe: probeResults({'claude': probeOk('2.1.81 (Claude Code)')}),
        authProbe: _authSucceeds,
      );

      final status = service.getAll().single;
      expect(status.health, 'healthy');
      expect(status.credentialStatus, 'oauth');
      expect(status.errorMessage, isNull);
      expect(service.getSummary(), {'configured': 1, 'healthy': 1, 'degraded': 0});
    });

    test('does not probe auth when API key is present', () async {
      var authProbeCalls = 0;
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
        registry: _registry(anthropicApiKey: 'anthropic-key'),
        defaultProvider: 'claude',
      );

      await service.probe(
        commandProbe: probeResults({'claude': probeOk('Claude CLI 2.0.0')}),
        authProbe: (executable, {String? providerId}) async {
          authProbeCalls++;
          return true;
        },
      );

      expect(authProbeCalls, 0, reason: 'auth probe should be skipped when API key is present');
      expect(service.getAll().single.credentialStatus, 'present');
    });

    test('falls back to degraded when OAuth auth probe also fails', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
        registry: _registry(),
        defaultProvider: 'claude',
      );

      await service.probe(commandProbe: probeResults({'claude': probeOk('Claude CLI 2.0.0')}), authProbe: _authFails);

      final status = service.getAll().single;
      expect(status.health, 'degraded');
      expect(status.credentialStatus, 'missing');
      expect(status.errorMessage, isNotNull);
    });

    test('probe caches version output for subsequent reads', () async {
      var probeCalls = 0;
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
        registry: _registry(anthropicApiKey: 'anthropic-key'),
        defaultProvider: 'claude',
      );

      await service.probe(
        commandProbe: (executable, arguments) async {
          probeCalls += 1;
          expect(executable, 'claude');
          expect(arguments, const ['--version']);
          return probeOk('Claude CLI 3.0.0')(executable, arguments);
        },
      );

      expect(service.getAll().single.version, 'Claude CLI 3.0.0');
      expect(service.getSummary(), {'configured': 1, 'healthy': 1, 'degraded': 0});
      expect(service.getAll().single.version, 'Claude CLI 3.0.0');
      expect(probeCalls, 1);
    });

    test('counts only task-pool workers toward activeWorkers', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 1)}),
        registry: _registry(openAiApiKey: 'openai-key'),
        defaultProvider: 'codex',
        pool: _buildPool(
          pools: pools,
          messages: messages,
          workspaceDir: tempDir.path,
          runners: const [
            (providerId: 'codex', state: WorkerState.busy),
            (providerId: 'codex', state: WorkerState.busy),
          ],
        ),
      );

      await service.probe(commandProbe: probeResults({'codex': probeOk('Codex CLI 3.0.0')}));

      expect(service.getAll().single.activeWorkers, 1);
    });

    test('handles non-zero exits, missing binaries, and empty version output', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: 'claude'),
            'codex': ProviderEntry(executable: 'codex'),
            'ghost': ProviderEntry(executable: 'ghost'),
          },
        ),
        registry: _registry(anthropicApiKey: 'anthropic-key', openAiApiKey: 'openai-key'),
        defaultProvider: 'claude',
      );

      await service.probe(
        commandProbe: probeResults({
          'claude': probeOk('', stderr: ''),
          'codex': probeExitCode(9, stdout: 'broken'),
          'ghost': probeMissing('ghost'),
        }),
      );

      final statuses = {for (final status in service.getAll()) status.id: status};

      expect(statuses['claude']!.binaryFound, isTrue);
      expect(statuses['claude']!.version, 'unknown');
      expect(statuses['claude']!.health, 'healthy');

      expect(statuses['codex']!.binaryFound, isFalse);
      expect(statuses['codex']!.version, isNull);
      expect(statuses['codex']!.health, 'unavailable');
      expect(statuses['codex']!.errorMessage, contains("Binary 'codex' for provider 'codex' was not found."));

      expect(statuses['ghost']!.binaryFound, isFalse);
      expect(statuses['ghost']!.version, isNull);
      expect(statuses['ghost']!.health, 'unavailable');
      expect(statuses['ghost']!.errorMessage, contains("Binary 'ghost' for provider 'ghost' was not found."));
    });

    test('normalizes noisy version output to the first non-empty line', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 1)}),
        registry: _registry(openAiApiKey: 'openai-key'),
        defaultProvider: 'codex',
      );

      await service.probe(
        commandProbe: probeResults({
          'codex': probeOk('\nCodex CLI 9.9.9\nextra detail', stderr: 'warning: noisy probe output'),
        }),
      );

      expect(service.getAll().single.version, 'Codex CLI 9.9.9');
    });
  });
}

CredentialRegistry _registry({String? anthropicApiKey, String? openAiApiKey, Map<String, String>? env}) {
  return CredentialRegistry(
    credentials: CredentialsConfig(
      entries: {
        if (anthropicApiKey != null) 'anthropic': CredentialEntry(apiKey: anthropicApiKey),
        if (openAiApiKey != null) 'openai': CredentialEntry(apiKey: openAiApiKey),
      },
    ),
    env: env,
  );
}

HarnessPool _buildPool({
  required List<HarnessPool> pools,
  required MessageService messages,
  required String workspaceDir,
  required List<({String providerId, WorkerState state})> runners,
}) {
  final pool = HarnessPool(
    runners: runners
        .map(
          (runner) => TurnRunner(
            harness: FakeAgentHarness(initialState: runner.state),
            messages: messages,
            behavior: BehaviorFileService(workspaceDir: workspaceDir),
            providerId: runner.providerId,
          ),
        )
        .toList(growable: false),
  );
  pools.add(pool);
  return pool;
}

Future<bool> _authSucceeds(String executable, {String? providerId}) async => true;

Future<bool> _authFails(String executable, {String? providerId}) async => false;
