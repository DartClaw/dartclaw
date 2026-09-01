import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:test/test.dart';

import 'helpers/probe_helpers.dart';
import 'execution_coordinator_test_support.dart';

void main() {
  late Directory tempDir;
  late MessageService messages;
  late List<ExecutionCoordinator> executions;
  late List<ExecutionLease> activeLeases;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('provider_status_service_test_');
    messages = MessageService(baseDir: tempDir.path);
    executions = <ExecutionCoordinator>[];
    activeLeases = <ExecutionLease>[];
  });

  tearDown(() async {
    for (final lease in activeLeases) {
      await lease.release();
    }
    for (final coordinator in executions) {
      await coordinator.dispose();
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
        executions: await _buildCoordinator(
          coordinators: executions,
          activeLeases: activeLeases,
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

      final statuses = service.all;
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
      expect(service.summary, {'configured': 1, 'healthy': 1, 'degraded': 0});
    });

    test('falls back to a single legacy codex provider and uses codex worker capacity', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig.defaults(),
        registry: _registry(openAiApiKey: 'openai-key'),
        defaultProvider: 'codex',
        executions: await _buildCoordinator(
          coordinators: executions,
          activeLeases: activeLeases,
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

      final statuses = service.all;
      expect(statuses, hasLength(1));

      final status = statuses.single;
      expect(status.id, 'codex');
      expect(status.executable, 'codex');
      expect(status.version, 'Codex CLI 0.9.0');
      expect(status.binaryFound, isTrue);
      expect(status.credentialStatus, 'present');
      expect(status.credentialEnvVar, 'CODEX_API_KEY');
      expect(status.poolSize, 2);
      expect(status.activeWorkers, 1);
      expect(status.isDefault, isTrue);
      expect(status.health, 'healthy');
      expect(status.errorMessage, isNull);
      expect(service.summary, {'configured': 1, 'healthy': 1, 'degraded': 0});
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
        executions: await _buildCoordinator(
          coordinators: executions,
          activeLeases: activeLeases,
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

      final statuses = {for (final status in service.all) status.id: status};
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
        'effectiveWorkers': 1,
        'activeWorkers': 1,
        'queuedWorkers': 0,
        'cachedWorkers': 0,
        'quarantinedWorkers': 0,
        'isDefault': true,
        'health': 'healthy',
        'errorMessage': null,
      });

      final codex = statuses['codex']!;
      expect(codex.health, 'degraded');
      expect(codex.credentialStatus, 'missing');
      expect(codex.credentialEnvVar, 'CODEX_API_KEY');
      expect(codex.binaryFound, isTrue);
      // The refusal text has one author in dartclaw_kernel, so the card cannot
      // name a fix the admission gate does not.
      expect(codex.errorMessage, contains('Provider "codex" has no credential configured'));
      expect(codex.errorMessage, contains('dartclaw auth codex'));
      expect(codex.errorMessage, contains('CODEX_API_KEY'));

      final ghost = statuses['ghost']!;
      expect(ghost.health, 'unavailable');
      expect(ghost.binaryFound, isFalse);
      expect(ghost.errorMessage, contains("Binary 'ghost' for provider 'ghost' was not found."));
      expect(ghost.errorMessage, contains('providers.ghost.executable'));
      expect(service.summary, {'configured': 3, 'healthy': 1, 'degraded': 1});
    });

    test('reports effective default worker capacity for an unset pool size', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude')}),
        registry: _registry(anthropicApiKey: 'anthropic-key'),
        defaultProvider: 'claude',
      );

      await service.probe(commandProbe: probeResults({'claude': probeOk('Claude CLI 1.0.0')}));

      expect(service.all.single.poolSize, 1);
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

      final status = service.all.single;
      expect(status.health, 'healthy');
      expect(status.credentialStatus, 'oauth');
      expect(status.errorMessage, isNull);
      expect(service.summary, {'configured': 1, 'healthy': 1, 'degraded': 0});
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
      expect(service.all.single.credentialStatus, 'present');
    });

    test('falls back to degraded when OAuth auth probe also fails', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
        registry: _registry(),
        defaultProvider: 'claude',
      );

      await service.probe(commandProbe: probeResults({'claude': probeOk('Claude CLI 2.0.0')}), authProbe: _authFails);

      final status = service.all.single;
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

      expect(service.all.single.version, 'Claude CLI 3.0.0');
      expect(service.summary, {'configured': 1, 'healthy': 1, 'degraded': 0});
      expect(service.all.single.version, 'Claude CLI 3.0.0');
      expect(probeCalls, 1);
    });

    test('counts only task-pool workers toward activeWorkers', () async {
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 1)}),
        registry: _registry(openAiApiKey: 'openai-key'),
        defaultProvider: 'codex',
        executions: await _buildCoordinator(
          coordinators: executions,
          activeLeases: activeLeases,
          messages: messages,
          workspaceDir: tempDir.path,
          runners: const [
            (providerId: 'codex', state: WorkerState.busy),
            (providerId: 'codex', state: WorkerState.busy),
          ],
        ),
      );

      await service.probe(commandProbe: probeResults({'codex': probeOk('Codex CLI 3.0.0')}));

      expect(service.all.single.activeWorkers, 1);
    });

    test('reports quarantined worker capacity as degraded provider health', () async {
      final coordinator = await _buildCoordinator(
        coordinators: executions,
        activeLeases: activeLeases,
        messages: messages,
        workspaceDir: tempDir.path,
        runners: const [
          (providerId: 'claude', state: WorkerState.idle),
          (providerId: 'claude', state: WorkerState.idle),
        ],
        terminationConfirmed: false,
      );
      final lease = await coordinator.acquire(
        ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: 'claude',
          policy: const ExecutionPolicy.host(),
          sessionId: 'unsafe',
        ),
      );
      (lease!.runner.harness as FakeAgentHarness).setState(WorkerState.crashed);
      await lease.release();

      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
        registry: _registry(anthropicApiKey: 'anthropic-key'),
        defaultProvider: 'claude',
        executions: coordinator,
      );
      await service.probe(commandProbe: probeResults({'claude': probeOk('Claude CLI 3.0.0')}));

      final status = service.all.single;
      expect(status.health, 'degraded');
      expect(status.effectiveWorkers, 0);
      expect(status.quarantinedWorkers, 1);
      expect(status.errorMessage, contains('Worker capacity degraded: 0 of 1 slots remain effective; 1 quarantined.'));
      expect(service.summary, {'configured': 1, 'healthy': 0, 'degraded': 1});
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

      final statuses = {for (final status in service.all) status.id: status};

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

    test('reports an aliased provider against the credential of its resolved family', () async {
      const providers = ProvidersConfig(
        entries: {
          'my_claude': ProviderEntry(executable: 'claude', poolSize: 1),
          'my_codex': ProviderEntry(executable: 'codex', poolSize: 1),
        },
      );
      final service = ProviderStatusService(
        providers: providers,
        registry: _registry(
          providers: providers,
          subscriptions: const {'claude': CredentialEntry.subscription(token: 'sk-ant-oat01-stored')},
        ),
        defaultProvider: 'my_claude',
      );

      await service.probe(
        commandProbe: probeResults({'claude': probeOk('Claude CLI 2.1.0'), 'codex': probeOk('Codex CLI 0.9.0')}),
        authProbe: _authFails,
      );

      final statuses = {for (final status in service.all) status.id: status};

      // The alias presents the stored claude subscription, so it is neither
      // credential-missing nor degraded.
      expect(statuses['my_claude']!.credentialStatus, 'present');
      expect(statuses['my_claude']!.health, 'healthy');
      expect(statuses['my_claude']!.errorMessage, isNull);

      // The resolved family decides: a codex alias must not read the stored
      // claude subscription as its own.
      expect(statuses['my_codex']!.credentialStatus, 'missing');
      expect(statuses['my_codex']!.health, 'degraded');
    });

    test('reports a canonical provider against a stored subscription unchanged', () async {
      const providers = ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: 'claude', poolSize: 1),
          'codex': ProviderEntry(executable: 'codex', poolSize: 1),
        },
      );
      final service = ProviderStatusService(
        providers: providers,
        registry: _registry(
          providers: providers,
          subscriptions: const {'claude': CredentialEntry.subscription(token: 'sk-ant-oat01-stored')},
        ),
        defaultProvider: 'claude',
      );

      await service.probe(
        commandProbe: probeResults({'claude': probeOk('Claude CLI 2.1.0'), 'codex': probeOk('Codex CLI 0.9.0')}),
        authProbe: _authFails,
      );

      final statuses = {for (final status in service.all) status.id: status};

      expect(statuses['claude']!.credentialStatus, 'present');
      expect(statuses['claude']!.health, 'healthy');
      expect(statuses['codex']!.credentialStatus, 'missing');
      expect(statuses['codex']!.health, 'degraded');
    });

    test('a forced subscription selection is missing while only an API key is configured', () async {
      const providers = ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1, auth: ProviderAuth.subscription)},
      );
      var authProbeCalls = 0;
      final service = ProviderStatusService(
        providers: providers,
        registry: _registry(anthropicApiKey: 'anthropic-key', providers: providers),
        defaultProvider: 'claude',
        credentialsDir: '/data/credentials',
      );

      await service.probe(
        commandProbe: probeResults({'claude': probeOk('Claude CLI 2.1.0')}),
        authProbe: (executable, {String? providerId}) async {
          authProbeCalls++;
          return true;
        },
      );

      // Admission refuses this provider: the configured key is not the
      // credential `auth: subscription` selects. A card reading `present` here
      // would promise an execution the gate will not start.
      final status = service.all.single;
      expect(status.credentialStatus, 'missing');
      expect(status.health, 'degraded');
      expect(status.errorMessage, contains('auth: subscription'));
      expect(status.errorMessage, contains('claude setup-token'));
      expect(status.errorMessage, contains('/data/credentials'), reason: 'the refusal names the store it searched');
      expect(authProbeCalls, 0, reason: 'a vendor login rescues only a provider with nothing configured');
    });

    test('a forced api_key selection is missing while only a subscription is stored', () async {
      const providers = ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1, auth: ProviderAuth.apiKey)},
      );
      var authProbeCalls = 0;
      final service = ProviderStatusService(
        providers: providers,
        registry: _registry(
          providers: providers,
          subscriptions: const {'claude': CredentialEntry.subscription(token: 'sk-ant-oat01-stored')},
        ),
        defaultProvider: 'claude',
      );

      await service.probe(
        commandProbe: probeResults({'claude': probeOk('Claude CLI 2.1.0')}),
        authProbe: (executable, {String? providerId}) async {
          authProbeCalls++;
          return true;
        },
      );

      final status = service.all.single;
      expect(status.credentialStatus, 'missing');
      expect(status.health, 'degraded');
      expect(status.errorMessage, contains('auth: api_key'));
      expect(status.errorMessage, contains('ANTHROPIC_API_KEY'));
      expect(authProbeCalls, 0, reason: 'a vendor login rescues only a provider with nothing configured');
    });

    test('a provider with nothing configured still reports the vendor login it probed', () async {
      var authProbeCalls = 0;
      final service = ProviderStatusService(
        providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
        registry: _registry(),
        defaultProvider: 'claude',
      );

      await service.probe(
        commandProbe: probeResults({'claude': probeOk('Claude CLI 2.1.0')}),
        authProbe: (executable, {String? providerId}) async {
          authProbeCalls++;
          return true;
        },
      );

      final status = service.all.single;
      expect(authProbeCalls, 1, reason: 'nothing configured is the one refusal a vendor login may answer');
      expect(status.credentialStatus, 'oauth');
      expect(status.health, 'healthy');
      expect(status.errorMessage, isNull);
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

      expect(service.all.single.version, 'Codex CLI 9.9.9');
    });
  });
}

CredentialRegistry _registry({
  String? anthropicApiKey,
  String? openAiApiKey,
  Map<String, String>? env,
  ProvidersConfig providers = const ProvidersConfig.defaults(),
  Map<String, CredentialEntry> subscriptions = const {},
}) {
  return CredentialRegistry(
    credentials: CredentialsConfig(
      entries: {
        if (anthropicApiKey != null) 'anthropic': CredentialEntry(apiKey: anthropicApiKey),
        if (openAiApiKey != null) 'openai': CredentialEntry(apiKey: openAiApiKey),
      },
    ),
    env: env,
    providers: providers,
    subscriptions: subscriptions,
  );
}

Future<ExecutionCoordinator> _buildCoordinator({
  required List<ExecutionCoordinator> coordinators,
  required List<ExecutionLease> activeLeases,
  required MessageService messages,
  required String workspaceDir,
  required List<({String providerId, WorkerState state})> runners,
  bool terminationConfirmed = true,
}) async {
  final runnerInstances = runners
      .map(
        (runner) => TurnRunner(
          turnLimits: const TurnLimitsConfig.defaults(),
          harness: _StatusHarness(terminationConfirmed: terminationConfirmed),
          messages: messages,
          behavior: BehaviorFileService(workspaceDir: workspaceDir),
          providerId: runner.providerId,
        ),
      )
      .toList(growable: false);
  final coordinator = coordinatorForRunners(runnerInstances);
  coordinators.add(coordinator);
  for (var index = 1; index < runners.length; index++) {
    final runner = runners[index];
    if (runner.state != WorkerState.busy) continue;
    final lease = await coordinator.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.workflow,
        providerId: runner.providerId,
        policy: const ExecutionPolicy.host(),
        sessionId: 'busy-$index',
      ),
    );
    activeLeases.add(lease!);
  }
  return coordinator;
}

final class _StatusHarness extends FakeAgentHarness {
  new({required this.terminationConfirmed}) : super(initialState: WorkerState.idle);

  final bool terminationConfirmed;

  @override
  bool get isRootProcessTerminationConfirmed => terminationConfirmed;
}

Future<bool> _authSucceeds(String executable, {String? providerId}) async => true;

Future<bool> _authFails(String executable, {String? providerId}) async => false;
