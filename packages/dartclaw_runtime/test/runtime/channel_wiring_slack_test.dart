import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show HealthService, SseBroadcast, TaskService;
import 'package:dartclaw_runtime/src/task/workflow_run_control.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowApprovalInteraction,
        WorkflowApprovalPost,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowService,
        WorkflowStep,
        WorkflowTaskType;
import 'package:dartclaw_workflow/testing.dart' show InMemoryWorkflowRunRepository;
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/config/config_load.dart';
import 'package:dartclaw_runtime/src/execution_policy_resolver.dart';
import 'package:dartclaw_runtime/src/logging/log_redactor.dart';
import 'package:dartclaw_runtime/src/runtime/channel_agent_binding.dart';
import 'package:dartclaw_runtime/src/runtime/channel_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/task_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager;
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../guard_audit_test_support.dart';
import 'harness_wiring_fixture.dart';

import 'channel_wiring_test_support.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-channel-wiring-test-');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('Slack and the reserved-command audit', () {
    const slackCredentials = '''
credentials:
  slack_bot:
    api_key: \${SLACK_BOT_TOKEN}
  slack_app:
    api_key: \${SLACK_APP_TOKEN}
  slack_signing:
    api_key: \${SLACK_SIGNING_SECRET}
''';
    const slackSection = '''
  slack:
    enabled: true
    bot_token_credential: slack_bot
    app_token_credential: slack_app
    dm_access: allowlist
    group_access: allowlist
    group_allowlist:
      - id: C0123ABC
        agent: ana
      - C0456DEF
''';
    const eventsSection = '''
  slack:
    enabled: true
    mode: events
    bot_token_credential: slack_bot
    signing_secret_credential: slack_signing
    dm_access: open
''';
    const agents = '''
agent:
  agents:
    ana:
      description: Ana
      prompt: You are Ana.
      provider: claude
      execution: host
''';

    Future<({ChannelWiring channels, RecordingChannelTurnManager turns, HealthService health})> wireChannels(
      String yaml, {
      GuardAuditLogger? auditLogger,
      MessageRedactor? redactor,
    }) async {
      final config = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml' ? 'data_dir: ${tempDir.path}\n$yaml' : null,
        env: {
          'HOME': tempDir.path,
          'SLACK_BOT_TOKEN': _slackBotToken,
          'SLACK_APP_TOKEN': _slackAppToken,
          'SLACK_SIGNING_SECRET': _slackSigningSecret,
        },
      );
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: neverExit);
      final task = TaskWiring(
        config: config,
        dataDir: config.server.dataDir,
        runtimeCwd: tempDir.path,
        eventBus: eventBus,
        storage: storage,
      );
      await task.wirePreServer();
      final ownerWorkspace = Directory(p.join(tempDir.path, 'workspace'))..createSync();
      final turns = RecordingChannelTurnManager();
      addTearDown(turns.executions.dispose);
      final health = HealthService(
        worker: FakeAgentHarness(),
        searchDbPath: config.searchDbPath,
        sessionsDir: config.sessionsDir,
        tasksDir: p.join(config.server.dataDir, 'tasks'),
      );
      final channels = ChannelWiring(
        config: config,
        dataDir: config.server.dataDir,
        port: 0,
        eventBus: eventBus,
        storage: storage,
        task: task,
        resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
        agentBinder: config.agent.definitions.isEmpty
            ? null
            : ChannelAgentBinder(
                agents: {for (final agent in config.agent.definitions) agent.id: agent},
                policyResolver: ExecutionPolicyResolver(config: config, availableContainerProfiles: const {}),
                defaultProviderId: 'claude',
                behavior: BehaviorFileService(workspaceDir: ownerWorkspace.path),
              ),
        auditLogger: auditLogger,
      );
      await channels.wire(
        serverRefGetter: () => throw StateError('the channel queue must use the injected turn manager'),
        turnManagerGetter: () => turns,
        sseBroadcast: SseBroadcast(),
        messageRedactor: redactor,
        healthService: health,
        configNotifier: ConfigNotifier(config),
      );
      addTearDown(() => channels.channelManager?.queue.dispose());
      return (channels: channels, turns: turns, health: health);
    }

    test('an enabled Slack section registers the channel with the manager', () async {
      final wired = await wireChannels(
        '$slackCredentials${'channels:\n  debounce_window_ms: 0\n$slackSection'}$agents',
      );

      final slack = wired.channels.slackChannel!;
      expect(wired.channels.channelManager!.channels, contains(slack));
      expect(slack.type, ChannelType.slack);
      expect(wired.channels.channelGroupConfigs.map((c) => c.channelType), isNot(contains('slack')));
    });

    test('run origin thread: a Slack thread message records the thread its capability extracts', () async {
      final wired = await wireChannels(
        '$slackCredentials${'channels:\n  debounce_window_ms: 0\n$slackSection'}$agents',
      );
      final manager = wired.channels.channelManager!;
      final inbound = ChannelMessage(
        channelType: ChannelType.slack,
        senderJid: 'U1',
        groupJid: 'C0456DEF',
        text: 'run the release check',
        metadata: {'spaceName': 'C0456DEF', threadIdMetadataKey: '1700000000.000100'},
      );
      final sessionKey = manager.deriveSessionKey(inbound);

      manager.handleInboundMessage(inbound);
      while (wired.turns.started.isEmpty) {
        await pumpEventQueue();
      }

      expect(
        wired.turns.started.single.provenance,
        TurnProvenance.channel(
          channelType: ChannelType.slack,
          recipientId: 'C0456DEF',
          threadId: 'C0456DEF:1700000000.000100',
          sessionKey: sessionKey,
          senderId: 'U1',
        ),
      );
    });

    const bindingChannelsYaml = 'channels:\n  debounce_window_ms: 0\n$slackSection';
    const chatNotificationsYaml = 'workflow:\n  chat_notifications:\n    channel: slack\n    recipient: C0456DEF\n';
    const threadBindingFlagYaml = 'features:\n  thread_binding:\n    enabled: true\n';

    test('no binding store is built when neither the flag nor chat_notifications asks for one', () async {
      final wired = await wireChannels('$slackCredentials$bindingChannelsYaml$agents');

      expect(wired.channels.threadBindingStore, isNull);
      expect(wired.channels.taskThreadBindingStore, isNull);
    });

    test('chat_notifications alone builds the live binding store, but task binding stays off', () async {
      final wired = await wireChannels('$slackCredentials$bindingChannelsYaml$agents$chatNotificationsYaml');

      expect(wired.channels.threadBindingStore, isNotNull);
      expect(wired.channels.taskThreadBindingStore, isNull, reason: 'the flag alone gates task binding');
    });

    test('the thread_binding flag builds one store that both run and task binding share', () async {
      final wired = await wireChannels('$slackCredentials$bindingChannelsYaml$agents$threadBindingFlagYaml');

      expect(wired.channels.threadBindingStore, isNotNull);
      expect(wired.channels.taskThreadBindingStore, same(wired.channels.threadBindingStore));
    });

    test('a disabled section registers nothing, and no channel manager is built for it alone', () async {
      final wired = await wireChannels('channels:\n  slack:\n    enabled: false\n');

      expect(wired.channels.slackChannel, isNull);
      expect(wired.channels.channelManager, isNull);
    });

    test('a bound allowlist row runs on the bound dispatch and an unbound row on the primary', () async {
      final wired = await wireChannels(
        '$slackCredentials${'channels:\n  debounce_window_ms: 0\n$slackSection'}$agents',
      );
      final manager = wired.channels.channelManager!;
      final replies = FakeChannel(type: ChannelType.slack, ownsAllJids: true);

      ChannelMessage inChannel(String channel) => ChannelMessage(
        channelType: ChannelType.slack,
        senderJid: 'U1',
        groupJid: channel,
        text: 'hello',
        metadata: {'spaceName': channel, threadIdMetadataKey: '1.5'},
      );
      final bound = inChannel('C0123ABC');
      final unbound = inChannel('C0456DEF');

      expect(manager.deriveSessionKey(bound), startsWith('agent:ana:group:slack:C0123ABC'));
      expect(manager.deriveSessionKey(unbound), startsWith('agent:main:group:slack:C0456DEF'));
      manager.queue.enqueue(bound, replies, manager.deriveSessionKey(bound));
      manager.queue.enqueue(unbound, replies, manager.deriveSessionKey(unbound));
      while (wired.turns.executed.isEmpty || wired.turns.started.isEmpty) {
        await pumpEventQueue();
      }

      expect(wired.turns.reserved.single.agentName, 'ana', reason: 'the logical-agent surface, never the primary lane');
      expect(wired.turns.started.single.promptScope, PromptScope.primary);
    });

    test('a refused reserved command reaches the audit entry through the wired channel manager', () async {
      final auditDir = Directory(p.join(tempDir.path, 'audit'))..createSync();
      final auditLogger = GuardAuditLogger(dataDir: auditDir.path);
      final wired = await wireChannels('''
governance:
  admin_senders: ["+46700000001"]
channels:
  signal:
    enabled: true
''', auditLogger: auditLogger);

      wired.channels.channelManager!.handleInboundMessage(
        ChannelMessage(channelType: ChannelType.signal, senderJid: '+46700000999', text: '/stop now'),
      );
      await pumpEventQueue(times: 200);
      await auditLogger.flush();

      final entries = File(auditLogger.auditFilePath).readAsLinesSync().map(jsonDecode).cast<Map<String, dynamic>>();
      expect(entries, hasLength(1));
      expect(entries.single, containsPair('guard', 'ReservedCommand'));
      expect(entries.single, containsPair('tool', '/stop'));
      expect(entries.single, containsPair('channel', 'signal'));
      expect(entries.single, containsPair('peerId', '+46700000999'));
    });

    group('run approvals', () {
      Future<(WorkflowService, InMemoryWorkflowRunRepository, WorkflowApprovalInteraction)> holdRun(
        EventBus eventBus,
      ) async {
        final repository = InMemoryWorkflowRunRepository();
        final workflows = WorkflowService.lifecycleOnly(
          repository: repository,
          taskService: TaskService(InMemoryTaskRepository(), eventBus: eventBus),
          messageService: MessageService(baseDir: p.join(tempDir.path, 'wf-sessions')),
          eventBus: eventBus,
          kvService: KvService(filePath: p.join(tempDir.path, 'wf-kv.json')),
          dataDir: tempDir.path,
        );
        addTearDown(workflows.dispose);
        final definition = WorkflowDefinition(
          name: 'approval-run',
          description: 'One approval gate',
          steps: const [
            WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          ],
        );
        final now = DateTime.now();
        await repository.insert(
          WorkflowRun(
            id: 'run-1',
            definitionName: definition.name,
            status: WorkflowRunStatus.awaitingApproval,
            startedAt: now,
            updatedAt: now,
            currentStepIndex: 1,
            definitionJson: definition.toJson(),
            contextJson: {
              '_approval.pending.stepId': 'gate',
              '_approval.pending.stepIndex': 0,
              'data': <String, dynamic>{},
              'variables': <String, dynamic>{},
            },
          ),
        );
        final interaction = (await workflows.issueApprovalInteraction('run-1', 'gate'))!;
        await workflows.bindApprovalPost(
          'run-1',
          nonce: interaction.nonce,
          post: const WorkflowApprovalPost(channelType: 'slack', recipientId: 'C1', messageId: '1700.01'),
        );
        return (workflows, repository, interaction);
      }

      SlackEnvelope click(WorkflowApprovalInteraction interaction) => SlackEnvelope(
        kind: SlackEnvelopeKind.blockAction,
        payload: {
          'type': 'block_actions',
          'user': {'id': 'U-ADMIN', 'name': 'Ada'},
          'container': {'type': 'message', 'message_ts': '1700.01', 'channel_id': 'C1'},
          'response_url': 'https://hooks.slack.invalid/actions/1',
          'actions': [
            {
              'type': 'button',
              'action_id': 'run_approve',
              'value': jsonEncode({'runId': 'run-1', 'stepId': 'gate', 'nonce': interaction.nonce}),
            },
          ],
        },
      );

      test('a click is unavailable until run control is bound, then resolves the run through the wired adapter', () async {
        const socketSection =
            '  slack:\n    enabled: true\n    bot_token_credential: slack_bot\n    app_token_credential: slack_app\n    dm_access: open\n';
        final wired = await wireChannels('$slackCredentials${'channels:\n  debounce_window_ms: 0\n$socketSection'}');
        final eventBus = EventBus();
        addTearDown(eventBus.dispose);
        final (workflows, repository, interaction) = await holdRun(eventBus);
        final audit = RecordingGuardAuditLogger();
        final request = ChannelRunApprovalRequest(
          action: ChannelRunApprovalAction.approve,
          runId: 'run-1',
          stepId: 'gate',
          nonce: interaction.nonce,
          senderId: 'U-ADMIN',
          channelType: 'slack',
          postMessageId: '1700.01',
        );

        expect(await wired.channels.runApprovalHandler(request), isA<ChannelRunApprovalFailed>());
        await wired.channels.slackChannel!.dispatch.dispatch(click(interaction));
        expect((await repository.getById('run-1'))!.status, WorkflowRunStatus.awaitingApproval);

        wired.channels.bindRunApprovals(
          WorkflowRunControl(workflows: workflows, isAdmin: (_) => true, auditLogger: audit).handleApproval,
        );
        await wired.channels.slackChannel!.dispatch.dispatch(click(interaction));
        await pumpEventQueue(times: 50);

        expect((await repository.getById('run-1'))!.status, isNot(WorkflowRunStatus.awaitingApproval));
        expect(audit.entries.map((e) => (e.hook, e.channel, e.peerId, e.decision)), [
          ('button', 'slack', 'U-ADMIN', 'allow'),
        ]);
      });
    });

    group('secrets and transport', () {
      final secrets = {'bot': _slackBotToken, 'app': _slackAppToken, 'signing': _slackSigningSecret};
      String eventsYaml() => '$slackCredentials${'channels:\n  debounce_window_ms: 0\n$eventsSection'}';
      String socketYaml() =>
          '$slackCredentials${'channels:\n  debounce_window_ms: 0\n  slack:\n    enabled: true\n    bot_token_credential: slack_bot\n    app_token_credential: slack_app\n    dm_access: open\n'}';

      /// What the redactor leaves of a line quoting every Slack secret, one by one.
      Set<String> leaked(MessageRedactor redactor) {
        final text = 'bot=${secrets['bot']} app=${secrets['app']} signing=${secrets['signing']}';
        final out = redactor.redact(text);
        return {
          for (final MapEntry(:key, :value) in secrets.entries)
            if (out.contains(value)) key,
        };
      }

      test(
        'events mode builds the handler, reports Slack on /health and registers exactly bot token and signing secret',
        () async {
          final redactor = MessageRedactor();
          final wired = await wireChannels(eventsYaml(), redactor: redactor);

          expect(wired.channels.slackChannel!.eventsHandler, isNotNull);
          final slack = (await wired.health.getStatus())['slack'] as Map<String, dynamic>;
          expect(slack['mode'], 'events');
          expect(leaked(redactor), {'app'}, reason: 'the app token is no consumer in events mode');
        },
      );

      test('socket mode builds no handler and registers exactly bot token and app token', () async {
        final redactor = MessageRedactor();
        final wired = await wireChannels(socketYaml(), redactor: redactor);

        expect(wired.channels.slackChannel!.eventsHandler, isNull);
        expect(leaked(redactor), {'signing'}, reason: 'the signing secret is no consumer in socket mode');
      });

      test('no Slack section means no `slack` key on /health', () async {
        final wired = await wireChannels('channels:\n  slack:\n    enabled: false\n');

        expect(await wired.health.getStatus(), isNot(contains('slack')));
      });

      test(
        'registered values are masked fully inside prose and assignments, and survive a pattern recompile',
        () async {
          final redactor = MessageRedactor();
          await wireChannels(eventsYaml(), redactor: redactor);

          for (final line in [
            'request failed: $_slackSigningSecret rejected',
            'SLACK_SIGNING_SECRET=$_slackSigningSecret',
          ]) {
            expect(redactor.redact(line), isNot(contains(_slackSigningSecret.substring(0, 4))));
          }
          redactor.recompilePatterns(['unrelated-[0-9]+']);
          expect(leaked(redactor), {'app'});
          expect(redactor.redact('token $_slackBotToken'), 'token [REDACTED]');
        },
      );

      for (final (mode, yaml, used) in <(String, String Function(), List<String>)>[
        ('events', eventsYaml, [_slackBotToken, _slackSigningSecret]),
        ('socket', socketYaml, [_slackBotToken, _slackAppToken]),
      ]) {
        test(
          '$mode mode: a handler error quoting its secrets and a failed verification reach no log, health or audit output',
          () async {
            final redactor = MessageRedactor();
            final auditDir = Directory(p.join(tempDir.path, 'audit'))..createSync();
            final audit = GuardAuditLogger(dataDir: auditDir.path);
            final wired = await wireChannels(yaml(), redactor: redactor, auditLogger: audit);
            final channel = wired.channels.slackChannel!;
            channel.dispatch.register(
              SlackEnvelopeKind.event,
              (_) => throw StateError('failed with ${used.join(' ')}'),
            );

            // What the sink writes: each record formatted through the redactor serve builds its log service on.
            final sink = LogRedactor(redactor: redactor);
            final written = <String>[];
            Logger.root.level = Level.ALL;
            final subscription = Logger.root.onRecord.listen(
              (r) => written.add(sink.redact('${r.message} ${r.error ?? ''} ${r.stackTrace ?? ''}')),
            );
            addTearDown(subscription.cancel);

            await channel.dispatch.dispatch(SlackEnvelope(kind: SlackEnvelopeKind.event, payload: const {}));
            if (mode == 'events') {
              final forged = Uint8List.fromList(utf8.encode('{"type":"event_callback"}'));
              await channel.eventsHandler!.handle(forged, signedSlackHeaders('another-secret', forged));
              await channel.eventsHandler!.handle(forged, const {});
            }
            await pumpEventQueue(times: 50);
            await audit.flush();

            expect(written.where((line) => line.contains('Slack event handler failed')), isNotEmpty);
            final auditFile = File(audit.auditFilePath);
            final outputs = [
              ...written,
              jsonEncode(await wired.health.getStatus()),
              if (auditFile.existsSync()) auditFile.readAsStringSync(),
            ];
            for (final output in outputs) {
              for (final secret in used) {
                expect(output, isNot(contains(secret)));
              }
            }
          },
        );
      }
    });
  });
}

const _slackBotToken = 'plain-bot-token-3f9a';
const _slackAppToken = 'plain-app-token-b42d';
const _slackSigningSecret = 'plain-signing-secret-7c1e';
