import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, HarnessFactory;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/scheduling_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeProjectService;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'channel_wiring_test_support.dart';
import 'harness_wiring_fixture.dart';

void main() {
  group('memory journal config validation', () {
    test('disabled journal leaves colliding user jobs unchanged', () {
      final config = DartclawConfig(
        memory: MemoryConfig(journalEnabled: false),
        scheduling: SchedulingConfig(
          jobs: [
            {
              'id': 'memory-journal',
              'prompt': 'Custom journal',
              'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
            },
          ],
        ),
      );

      expect(validateMemoryJournalConfig(config), isNull);
    });

    for (final identityKey in ['id', 'name']) {
      test('enabled journal rejects a user $identityKey collision before wiring', () {
        final config = DartclawConfig(
          memory: MemoryConfig(journalEnabled: true),
          scheduling: SchedulingConfig(
            jobs: [
              {
                identityKey: 'memory-journal',
                'prompt': 'Custom journal',
                'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
              },
            ],
          ),
        );

        expect(
          () => validateMemoryJournalConfig(config),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(contains('memory-journal'), contains('memory.journal'), contains('scheduling.jobs')),
            ),
          ),
        );
      });
    }

    test('enabled journal rejects an invalid cron with the standard parser error', () {
      final config = DartclawConfig(memory: MemoryConfig(journalEnabled: true, journalSchedule: 'not-a-cron'));

      expect(() => validateMemoryJournalConfig(config), throwsFormatException);
      expect(() => CronExpression.parse('not-a-cron'), throwsFormatException);
    });
  });

  group('memory curation config validation', () {
    test('disabled curation leaves colliding user jobs unchanged', () {
      final config = DartclawConfig(
        memory: MemoryConfig(curationEnabled: false),
        scheduling: SchedulingConfig(
          jobs: [
            {
              'id': memoryCurationJobId,
              'prompt': 'Custom curation',
              'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
            },
          ],
        ),
      );

      expect(validateMemoryCurationConfig(config), isNull);
    });

    // The built-in used to reserve this ID globally and reject the collision at
    // request time with a 409; now it is an ordinary duplicate refused at load.
    for (final identityKey in ['id', 'name']) {
      test('enabled curation rejects a user $identityKey collision before wiring', () {
        final config = DartclawConfig(
          memory: MemoryConfig(curationEnabled: true),
          scheduling: SchedulingConfig(
            jobs: [
              {
                identityKey: memoryCurationJobId,
                'prompt': 'Custom curation',
                'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
              },
            ],
          ),
        );

        expect(
          () => validateMemoryCurationConfig(config),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('Duplicate scheduled job ID'),
                contains(memoryCurationJobId),
                contains('memory.curation'),
                contains('scheduling.jobs'),
              ),
            ),
          ),
        );
      });
    }

    test('enabled curation rejects an invalid cron with the standard parser error', () {
      final config = DartclawConfig(memory: MemoryConfig(curationEnabled: true, curationSchedule: 'not-a-cron'));

      expect(() => validateMemoryCurationConfig(config), throwsFormatException);
    });

    test('enabled curation parses its schedule', () {
      final config = DartclawConfig(memory: MemoryConfig(curationEnabled: true, curationSchedule: '0 4 * * *'));

      expect(validateMemoryCurationConfig(config)!.hours, {4});
    });
  });

  group('managed memory policy', () {
    test('empty allowlist retains the existing allow-all cascade semantics', () {
      const definition = AgentDefinition(id: 'generalist', description: '', prompt: '');
      final policy = ManagedMemoryPolicy(const DartclawConfig(agent: AgentConfig(definitions: [definition])));

      expect(policy.allowsRead(definition), isTrue);
      expect(policy.allowsWrite(definition), isTrue);
    });

    test('an explicit helper allowlist grants only its resolved memory capability', () {
      const readOnly = AgentDefinition(id: 'reader', description: '', prompt: '', allowedTools: {'memory_read'});
      const webOnly = AgentDefinition(id: 'web', description: '', prompt: '', allowedTools: {'web_search'});
      final policy = ManagedMemoryPolicy(const DartclawConfig(agent: AgentConfig(definitions: [readOnly, webOnly])));

      expect(policy.allowsRead(readOnly), isTrue);
      expect(policy.allowsWrite(readOnly), isFalse);
      expect(policy.allowsCorpus(webOnly), isFalse);
    });
  });

  group('workspace git sync', () {
    late Directory tempDir;
    late EventBus eventBus;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_scheduling_git_sync_');
      eventBus = EventBus();
    });

    tearDown(() async {
      await eventBus.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<({SchedulingWiring scheduling, List<String> warnings, String workspaceDir})> wireScheduling({
      required bool containersEnabled,
    }) async {
      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
        agent: const AgentConfig(provider: 'claude'),
        providers: ProvidersConfig(
          entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
        ),
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        gateway: const GatewayConfig(authMode: 'none'),
        workspace: const WorkspaceConfig(gitSyncEnabled: true),
      );
      final wired = await wireTestChannels(config, runtimeCwd: tempDir.path, eventBus: eventBus);
      addTearDown(wired.storage.dispose);
      final auditLogger = GuardAuditLogger(dataDir: tempDir.path);
      final security = containersEnabled
          ? ContainerCapableSecurityWiring(
              config: config,
              dataDir: tempDir.path,
              runtimeCwd: tempDir.path,
              eventBus: eventBus,
              exitFn: neverExit,
              auditLogger: auditLogger,
            )
          : SecurityWiring(
              config: config,
              dataDir: tempDir.path,
              runtimeCwd: tempDir.path,
              eventBus: eventBus,
              exitFn: neverExit,
              auditLogger: auditLogger,
            );
      await security.wire(agentDefs: [AgentDefinition.searchAgent()]);
      addTearDown(security.dispose);
      final harness = await wireTestHarness(
        config: config,
        dataDir: tempDir.path,
        harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
        exitFn: neverExit,
        storage: wired.storage,
        security: security,
        eventBus: eventBus,
        serverRefGetter: () => throw StateError('no server in this test'),
      );
      addTearDown(harness.executions.dispose);

      final scheduling = SchedulingWiring(
        config: config,
        eventBus: eventBus,
        storage: wired.storage,
        channel: wired.channels,
        security: security,
        sseBroadcast: harness.sseBroadcast!,
        memoryHandlers: harness.memoryHandlers,
        credentialHealth: CredentialHealthMonitor(
          eventBus: eventBus,
          providerStatus: ProviderStatusService(
            providers: config.providers,
            registry: CredentialRegistry(credentials: config.credentials),
            defaultProvider: 'claude',
          ),
          resolveCredentials: () => const {},
        ),
        messageRedactor: MessageRedactor(),
      );
      addTearDown(scheduling.dispose);
      final records = <LogRecord>[];
      final subscription = Logger('SchedulingWiring').onRecord.listen(records.add);
      try {
        await scheduling.wire(
          turns: RecordingChannelTurnManager(),
          contextMonitor: harness.contextMonitor,
          policyResolver: harness.policyResolver,
          configWriter: ConfigWriter(configPath: p.join(tempDir.path, 'dartclaw.yaml')),
          projects: FakeProjectService(),
        );
      } finally {
        await subscription.cancel();
      }
      addTearDown(() => scheduling.scheduleService?.stop());
      return (
        scheduling: scheduling,
        workspaceDir: config.workspaceDir,
        warnings: [
          for (final record in records)
            if (record.level == Level.WARNING) record.message,
        ],
      );
    }

    // Containers mount the workspace read-write, so host Git there would run
    // agent-planted hooks and config: the sync must not exist, not merely be paused.
    test('is never built under container isolation, and the workspace gets no repository', () async {
      final wired = await wireScheduling(containersEnabled: true);

      expect(wired.scheduling.gitSync, isNull);
      expect(
        wired.scheduling.scheduleService!.jobsForTesting.map((job) => job.id),
        isNot(contains(workspaceGitSyncJobId)),
      );
      expect(wired.scheduling.systemJobNames, isNot(contains(workspaceGitSyncJobId)));
      expect(wired.scheduling.displayJobs.map((job) => job['name']), isNot(contains(workspaceGitSyncJobId)));
      expect(Directory(p.join(wired.workspaceDir, '.git')).existsSync(), isFalse);
      expect(
        wired.warnings,
        contains(allOf(contains('Workspace git sync is disabled under container isolation'), contains('write'))),
      );
    });

    test('is registered and initializes the workspace repository without container isolation', () async {
      final wired = await wireScheduling(containersEnabled: false);

      expect(wired.scheduling.gitSync, isNotNull);
      final schedule = wired.scheduling.scheduleService!;
      expect(schedule.jobsForTesting.map((job) => job.id), contains(workspaceGitSyncJobId));
      expect(schedule.isJobPaused(workspaceGitSyncJobId), isFalse);
      expect(wired.scheduling.systemJobNames, contains(workspaceGitSyncJobId));
      expect(Directory(p.join(wired.workspaceDir, '.git')).existsSync(), isTrue);
      expect(wired.warnings, isNot(contains(contains('container isolation'))));
    });
  });
}
