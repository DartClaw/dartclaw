import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/runtime/service_wiring.dart' show reconcileThreadBindings, wireRunNotifications;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, WorkflowRunOrigin, WorkflowService;
import 'package:dartclaw_workflow/testing.dart' show InMemoryWorkflowRunRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> _resolvePackageDir(String packageRelativeAnchor) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/$packageRelativeAnchor'));
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_runtime $packageRelativeAnchor via package URI');
  }
  return p.dirname(uri.toFilePath());
}

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory tempDir;
  late ThreadBindingStore store;
  late EventBus eventBus;
  late InMemoryWorkflowRunRepository repository;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('service_wiring_run_notifications_');
    store = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    await store.load();
    eventBus = EventBus();
    repository = InMemoryWorkflowRunRepository();
    logs = [];
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logSubscription.cancel();
    await eventBus.dispose();
    tempDir.deleteSync(recursive: true);
  });

  Future<WorkflowRun> addRun(String id, {WorkflowRunStatus status = WorkflowRunStatus.running}) async {
    final now = DateTime.utc(2026, 10, 6);
    final run = WorkflowRun(
      id: id,
      definitionName: 'code-review',
      status: status,
      startedAt: now,
      updatedAt: now,
      origin: const WorkflowRunOrigin(surface: 'web'),
    );
    await repository.insert(run);
    return run;
  }

  void runStarted(String runId) => eventBus.fire(
    WorkflowRunStatusChangedEvent(
      runId: runId,
      definitionName: 'code-review',
      oldStatus: WorkflowRunStatus.pending,
      newStatus: WorkflowRunStatus.running,
      timestamp: DateTime.utc(2026, 10, 6, 1),
    ),
  );

  Future<void> settle() async {
    await pumpEventQueue(times: 50);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  DartclawConfig configWith({WorkflowChatNotificationsConfig? chatNotifications, bool threadBinding = false}) =>
      DartclawConfig(
        workflow: WorkflowConfig(chatNotifications: chatNotifications),
        features: FeaturesConfig(threadBinding: ThreadBindingFeatureConfig(enabled: threadBinding)),
        server: const ServerConfig(baseUrl: 'https://dartclaw.example'),
      );

  ChannelManager managerOf(List<Channel> channels) {
    final manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults());
    channels.forEach(manager.registerChannel);
    return manager;
  }

  group('wireRunNotifications', () {
    test('chat_notifications alone gives every run its own thread and run binding, and no task binding', () async {
      final threads = FakeThreadedNotifications();
      final channel = FakeChannel(type: ChannelType.slack, ownsAllJids: true, threadedNotifications: threads);
      final subscriber = wireRunNotifications(
        config: configWith(
          chatNotifications: const WorkflowChatNotificationsConfig(channel: ChannelType.slack, recipient: 'C0NOTIFY'),
        ),
        eventBus: eventBus,
        lookupRun: repository.getById,
        channelManager: managerOf([channel]),
        threadBindings: store,
      )!;
      addTearDown(subscriber.dispose);
      await addRun('run-a');
      await addRun('run-b');

      runStarted('run-a');
      runStarted('run-b');
      await settle();

      expect(threads.sends.map((s) => (s.recipientId, s.threadKey)), [
        ('C0NOTIFY', 'run-run-a'),
        ('C0NOTIFY', 'run-run-b'),
      ]);
      expect(store.lookupByRun('run-a'), hasLength(1));
      expect(store.lookupByRun('run-b'), hasLength(1));
      expect([
        for (final run in ['run-a', 'run-b']) ...store.lookupByRun(run).map((b) => b.kind),
      ], everyElement(ThreadBindingKind.run));
      expect(channel.sentMessages, isEmpty);
    });

    test(
      'a configured channel that is not registered warns, posts nothing and leaves chat-origin runs alone',
      () async {
        final slackThreads = FakeThreadedNotifications();
        final slack = FakeChannel(type: ChannelType.slack, ownsAllJids: true, threadedNotifications: slackThreads);
        final subscriber = wireRunNotifications(
          config: configWith(
            chatNotifications: const WorkflowChatNotificationsConfig(
              channel: ChannelType.googlechat,
              recipient: 'spaces/AAA',
            ),
          ),
          eventBus: eventBus,
          lookupRun: repository.getById,
          channelManager: managerOf([slack]),
          threadBindings: store,
        )!;
        addTearDown(subscriber.dispose);
        await addRun('run-web');
        final now = DateTime.utc(2026, 10, 6);
        await repository.insert(
          WorkflowRun(
            id: 'run-chat',
            definitionName: 'code-review',
            startedAt: now,
            updatedAt: now,
            origin: const WorkflowRunOrigin(
              surface: 'slack',
              channelType: 'slack',
              recipientId: 'C1',
              threadId: 'C1:1.5',
            ),
          ),
        );

        runStarted('run-web');
        runStarted('run-chat');
        await settle();

        expect(
          logs.where((r) => r.level == Level.WARNING && r.message.contains('workflow.chat_notifications.channel')),
          hasLength(1),
        );
        expect(slackThreads.sends.map((s) => (s.recipientId, s.threadId)), [('C1', 'C1:1.5')]);
      },
    );

    test('a recipient the configured channel does not own warns and posts nothing', () async {
      final whatsapp = FakeChannel(type: ChannelType.whatsapp, ownedJids: {'group@g.us'});
      final subscriber = wireRunNotifications(
        config: configWith(
          chatNotifications: const WorkflowChatNotificationsConfig(
            channel: ChannelType.whatsapp,
            recipient: 'not-a-whatsapp-jid',
          ),
        ),
        eventBus: eventBus,
        lookupRun: repository.getById,
        channelManager: managerOf([whatsapp]),
        threadBindings: store,
      )!;
      addTearDown(subscriber.dispose);
      await addRun('run-web');

      runStarted('run-web');
      await settle();

      expect(whatsapp.sentMessages, isEmpty);
      expect(
        logs.where((r) => r.level == Level.WARNING && r.message.contains('workflow.chat_notifications.recipient')),
        hasLength(1),
      );
    });

    test('there is nothing to subscribe without a channel manager', () {
      expect(
        wireRunNotifications(
          config: configWith(),
          eventBus: eventBus,
          lookupRun: repository.getById,
          channelManager: null,
          threadBindings: null,
        ),
        isNull,
      );
    });

    test('the subscriber stops posting once disposed, as shutdown disposes it', () async {
      final threads = FakeThreadedNotifications();
      final channel = FakeChannel(type: ChannelType.slack, ownsAllJids: true, threadedNotifications: threads);
      final subscriber = wireRunNotifications(
        config: configWith(
          chatNotifications: const WorkflowChatNotificationsConfig(channel: ChannelType.slack, recipient: 'C0NOTIFY'),
        ),
        eventBus: eventBus,
        lookupRun: repository.getById,
        channelManager: managerOf([channel]),
        threadBindings: store,
      )!;
      await addRun('run-a');

      await subscriber.dispose();
      runStarted('run-a');
      await settle();

      expect(threads.sends, isEmpty);
    });
  });

  group('reconcileThreadBindings', () {
    test('keeps the threads of active runs and tasks and drops terminal, unknown and finished ones', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      await tasks.create(id: 'task-active', title: 'Active', description: 'Active', autoStart: true);
      await tasks.transition('task-active', TaskStatus.running);
      await tasks.create(id: 'task-done', title: 'Done', description: 'Done', autoStart: true);
      await tasks.transition('task-done', TaskStatus.running);
      await tasks.transition('task-done', TaskStatus.failed);
      await addRun('run-active');
      await addRun('run-done', status: WorkflowRunStatus.completed);
      final workflows = WorkflowService.lifecycleOnly(
        repository: repository,
        taskService: tasks,
        messageService: MessageService(baseDir: p.join(tempDir.path, 'sessions')),
        eventBus: eventBus,
        kvService: KvService(filePath: p.join(tempDir.path, 'kv.json')),
        dataDir: tempDir.path,
      );
      final now = DateTime.now();
      Future<void> bindRun(String id) => store.create(
        ThreadBinding.run(channelType: 'slack', threadId: 'C1:$id', runId: id, createdAt: now, lastActivity: now),
      );
      Future<void> bindTask(String id) => store.create(
        ThreadBinding.task(
          channelType: 'slack',
          threadId: 'C1:$id',
          taskId: id,
          sessionKey: 'sk:$id',
          createdAt: now,
          lastActivity: now,
        ),
      );
      await Future.wait([
        bindRun('run-active'),
        bindRun('run-done'),
        bindRun('run-unknown'),
        bindTask('task-active'),
        bindTask('task-done'),
      ]);

      final pruned = await reconcileThreadBindings(store, tasks: tasks, workflows: workflows);

      expect(pruned, 3, reason: 'a finished run, an unknown run and a finished task');
      expect(store.lookupByRun('run-active'), hasLength(1));
      expect(store.lookupByTask('task-active'), hasLength(1));
      expect(store.lookupByRun('run-done'), isEmpty);
      expect(store.lookupByRun('run-unknown'), isEmpty);
      expect(store.lookupByTask('task-done'), isEmpty);
    });
  });

  group('the assembled runtime', () {
    late String staticDirPath;
    late String templatesDirPath;
    late HttpServer gowa;
    late List<Map<String, dynamic>> gowaMessages;

    setUpAll(() async {
      staticDirPath = await _resolvePackageDir('src/static/app.js');
      templatesDirPath = await _resolvePackageDir('src/templates/audit_table.dart');
    });

    setUp(() async {
      gowaMessages = [];
      gowa = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gowa.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        if (request.method == 'POST' && request.uri.path == '/send/message') {
          gowaMessages.add(jsonDecode(body) as Map<String, dynamic>);
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'code': 'SUCCESS', 'results': {}}));
        await request.response.close();
      });
    });

    tearDown(() => gowa.close(force: true));

    test('a run started outside chat posts into the configured WhatsApp group until shutdown', () async {
      final dataDir = Directory(p.join(tempDir.path, 'data'))..createSync(recursive: true);
      final config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
        providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
        gateway: const GatewayConfig(authMode: 'none'),
        channels: ChannelConfig(
          channelConfigs: {
            'whatsapp': {'enabled': true, 'gowa_port': gowa.port},
          },
        ),
        workflow: const WorkflowConfig(
          chatNotifications: WorkflowChatNotificationsConfig(
            channel: ChannelType.whatsapp,
            recipient: '120363000000000000@g.us',
          ),
        ),
        server: ServerConfig(
          dataDir: dataDir.path,
          staticDir: staticDirPath,
          templatesDir: templatesDirPath,
          claudeExecutable: Platform.resolvedExecutable,
        ),
      );
      final factory = HarnessFactory()..register('claude', (_) => FakeAgentHarness());
      final runs = InMemoryWorkflowRunRepository();
      final runtime = await DartclawRuntime.build(
        config,
        dataDir: dataDir.path,
        port: 3000,
        harnessFactory: factory,
        taskBackendFactory: (_) async => openPreparedTaskBackend(),
        taskBackendIsPrepared: true,
        taskRepositoryFactory: (_) => InMemoryTaskRepository(),
        workflowRunRepositoryFactory: (_) => runs,
        resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
        messageRedactor: MessageRedactor(),
        resolvedAssets: ResolvedAssets.fromSourceTree(
          templatesDir: config.server.templatesDir,
          staticDir: config.server.staticDir,
          source: AssetSource.sourceTreeDefault,
        ),
        runWorkflowSkillsBootstrap: false,
        stderrLine: (_) {},
        exitFn: _unexpectedExit,
        environment: {'HOME': tempDir.path},
      );
      var shutDown = false;
      addTearDown(() async {
        if (!shutDown) await runtime.shutdownExtras();
      });
      final now = DateTime.utc(2026, 10, 6);
      await runs.insert(
        WorkflowRun(
          id: 'run-wired',
          definitionName: 'code-review',
          startedAt: now,
          updatedAt: now,
          origin: const WorkflowRunOrigin(surface: 'api'),
        ),
      );

      runtime.eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: 'run-wired',
          definitionName: 'code-review',
          oldStatus: WorkflowRunStatus.pending,
          newStatus: WorkflowRunStatus.running,
          timestamp: now,
        ),
      );
      for (var i = 0; i < 100 && gowaMessages.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(gowaMessages, hasLength(1));
      expect(gowaMessages.single['phone'], '120363000000000000@g.us');
      expect(
        gowaMessages.single['message'],
        allOf(contains("'code-review'"), contains('run-wired'), contains('started')),
      );

      await runtime.shutdownExtras();
      shutDown = true;
      await runs.insert(
        WorkflowRun(
          id: 'run-after-shutdown',
          definitionName: 'code-review',
          startedAt: now,
          updatedAt: now,
          origin: const WorkflowRunOrigin(surface: 'api'),
        ),
      );
      runtime.eventBus.fire(
        WorkflowRunStatusChangedEvent(
          runId: 'run-after-shutdown',
          definitionName: 'code-review',
          oldStatus: WorkflowRunStatus.pending,
          newStatus: WorkflowRunStatus.running,
          timestamp: now,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(gowaMessages, hasLength(1), reason: 'shutdown disposed the subscriber');
    });
  });
}
