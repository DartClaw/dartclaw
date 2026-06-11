import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/auth/request_auth_context.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import '../whatsapp_test_support.dart';
import 'api_test_helpers.dart';

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;

  void writeConfigYaml([String extra = '']) {
    final trimmedExtra = extra.trimRight();
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
${trimmedExtra.isEmpty ? '' : '$trimmedExtra\n'}scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_api_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();

    writeConfigYaml();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// Creates a test router with injected dependencies.
  Router createRouter({DartclawConfig? config, RuntimeConfig? runtime, EventBus? eventBus}) {
    final cfg = config ?? const DartclawConfig.defaults();
    final rc =
        runtime ??
        RuntimeConfig(
          heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
          gitSyncEnabled: cfg.workspace.gitSyncEnabled,
          gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
        );
    final writer = ConfigWriter(configPath: configPath);
    final validator = const ConfigValidator();

    // Wire EventBus + ConfigChangeSubscriber so live field side-effects work.
    final bus = eventBus ?? EventBus();
    ConfigChangeSubscriber(runtimeConfig: rc).subscribe(bus);

    return configApiRoutes(
      config: cfg,
      writer: writer,
      validator: validator,
      runtimeConfig: rc,
      dataDir: dataDir,
      eventBus: bus,
    );
  }

  /// Creates a test router with a WhatsApp channel's DM access controller.
  Router createRouterWithPairing({required DmAccessController dmAccessController}) {
    final cfg = const DartclawConfig.defaults();
    final rc = RuntimeConfig(
      heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
      gitSyncEnabled: cfg.workspace.gitSyncEnabled,
      gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
    );
    final writer = ConfigWriter(configPath: configPath);
    final validator = const ConfigValidator();

    writeConfigYaml('''
channels:
  whatsapp:
    enabled: true
    dm_access: pairing
    dm_allowlist: []''');

    final waChannel = WhatsAppChannel(
      gowa: FakeGowaManager(),
      config: const WhatsAppConfig(enabled: true),
      dmAccess: dmAccessController,
      mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
      workspaceDir: tempDir.path,
    );

    return configApiRoutes(
      config: cfg,
      writer: writer,
      validator: validator,
      runtimeConfig: rc,
      dataDir: dataDir,
      whatsAppChannel: waChannel,
    );
  }

  ApiRouteTestClient api(Router router) {
    return ApiRouteTestClient(router.call);
  }

  ApiRouteTestClient adminApi(Router router) {
    return ApiRouteTestClient((request) => router.call(withAdminAuthContext(request)));
  }

  Future<String> nextSseFrame(StreamIterator<String> iterator) async {
    final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
    expect(hasFrame, isTrue);
    return iterator.current;
  }

  /// Writes jobs to the YAML config file so [ConfigWriter.readSchedulingJobs]
  /// returns them (tests that need pre-existing jobs must call this).
  void writeJobsToYaml(List<Map<String, dynamic>> jobs) {
    final jobsYaml = jobs
        .map((j) {
          return '  - name: ${j['name']}\n'
              '    schedule: "${j['schedule']}"\n'
              '    prompt: "${j['prompt']}"\n'
              '    delivery: ${j['delivery']}';
        })
        .join('\n');
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs:
$jobsYaml
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
  }

  group('GET /api/config', () {
    test('returns 200 with full config JSON', () async {
      final router = createRouter();

      final json = await api(router).expectJsonObject('GET', '/api/config');

      expect(json['port'], 3000);
      expect(json['host'], 'localhost');
      expect(json.containsKey('_meta'), isTrue);
    });

    test('contains _meta.fields map', () async {
      final router = createRouter();
      final json = await api(router).expectJsonObject('GET', '/api/config');

      final meta = json['_meta'] as Map<String, dynamic>;
      expect(meta.containsKey('fields'), isTrue);
      final fields = meta['fields'] as Map<String, dynamic>;
      expect(fields.containsKey('port'), isTrue);
      expect(fields.containsKey('scheduling.heartbeat.enabled'), isTrue);
    });

    for (final testCase in const [
      (name: 'lastBackup null when no backup', key: 'lastBackup', expected: null),
      (name: 'restartPending false when no pending file', key: 'restartPending', expected: false),
    ]) {
      test('contains _meta.${testCase.name}', () async {
        final json = await api(createRouter()).expectJsonObject('GET', '/api/config');
        final meta = json['_meta'] as Map<String, dynamic>;
        expect(meta[testCase.key], testCase.expected);
        if (testCase.key == 'restartPending') expect(meta['pendingFields'], isEmpty);
      });
    }

    test('gateway.token is masked', () async {
      writeConfigYaml('''
gateway:
  token: secret-token''');
      final router = createRouter(
        config: const DartclawConfig(gateway: GatewayConfig(token: 'secret-token')),
      );
      final json = await api(router).expectJsonObject('GET', '/api/config');

      final gateway = json['gateway'] as Map<String, dynamic>;
      expect(gateway['token'], '***');
    });

    test('google chat inline service account is redacted in API response', () async {
      writeConfigYaml('''
channels:
  google_chat:
    enabled: true
    service_account: '{"type":"service_account","client_email":"chat-bot@example.iam.gserviceaccount.com","private_key":"secret"}'
    audience:
      type: project-number
      value: "123456789"''');
      final router = createRouter();
      final json = await api(router).expectJsonObject('GET', '/api/config');

      final channels = json['channels'] as Map<String, dynamic>;
      final googleChat = channels['googleChat'] as Map<String, dynamic>;
      expect(googleChat['serviceAccount'], 'chat-bot@example.iam.gserviceaccount.com');
    });

    test('whatsapp config is serialized from parsed typed config', () async {
      writeConfigYaml('''
channels:
  whatsapp:
    enabled: nope
    dm_access: invalid
    group_access: invalid
    require_mention: invalid''');
      final router = createRouter();
      final json = await api(router).expectJsonObject('GET', '/api/config');

      final channels = json['channels'] as Map<String, dynamic>;
      final whatsapp = channels['whatsapp'] as Map<String, dynamic>;
      expect(whatsapp['enabled'], isFalse);
      expect(whatsapp['dmAccess'], 'pairing');
      expect(whatsapp['groupAccess'], 'disabled');
      expect(whatsapp['requireMention'], isTrue);
    });

    test('github config is loaded from disk via the typed extension parser', () async {
      writeConfigYaml('''
github:
  enabled: true
  webhook_secret: secret
  webhook_path: /hooks/github''');
      final router = createRouter();
      final json = await api(router).expectJsonObject('GET', '/api/config');

      final github = json['github'] as Map<String, dynamic>;
      expect(github['enabled'], isTrue);
      expect(github['webhookSecret'], '***');
      expect(github['webhookPath'], '/hooks/github');
      final meta = json['_meta'] as Map<String, dynamic>;
      expect((meta['fields'] as Map<String, dynamic>).containsKey('github.enabled'), isTrue);
    });
  });

  group('GET /api/scheduling/jobs', () {
    test('returns jobs from the current YAML config', () async {
      writeJobsToYaml([
        {'name': 'daily-summary', 'schedule': '0 8 * * *', 'prompt': 'Summarize', 'delivery': 'announce'},
      ]);
      final router = createRouter();

      final body = await api(router).expectJsonList('GET', '/api/scheduling/jobs');

      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['name'], 'daily-summary');
    });

    test('returns a single job by name', () async {
      writeJobsToYaml([
        {'name': 'daily-summary', 'schedule': '0 8 * * *', 'prompt': 'Summarize', 'delivery': 'announce'},
      ]);
      final router = createRouter();

      final body = await api(router).expectJsonObject('GET', '/api/scheduling/jobs/daily-summary');

      expect(body['name'], 'daily-summary');
    });

    test('returns 404 when a job does not exist', () async {
      final router = createRouter();

      final code = await api(router).expectJsonErrorCode('GET', '/api/scheduling/jobs/missing', status: 404);

      expect(code, 'JOB_NOT_FOUND');
    });
  });

  group('PATCH /api/config — validation', () {
    test('request without admin context returns 403 before mutating config', () async {
      final router = createRouter();
      final json = await api(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'guards.content.enabled': false}, status: 403);

      expect(json, containsPair('error', containsPair('code', 'FORBIDDEN')));
    });

    test('no-auth pipeline (auth_mode: none) lets an unauthenticated request patch config', () async {
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);
      final router = createRouter(runtime: runtime);
      // localAdminMiddleware is what the server installs when auth is disabled;
      // without it the admin gate above would 403 every request in no-auth mode.
      final handler = const Pipeline().addMiddleware(localAdminMiddleware()).addHandler(router.call);
      final json = await ApiRouteTestClient(
        handler,
      ).expectJsonObject('PATCH', '/api/config', json: {'scheduling.heartbeat.enabled': false});

      expect(json['applied'], ['scheduling.heartbeat.enabled']);
      expect(runtime.heartbeatEnabled, false);
    });

    test('empty body returns 400', () async {
      final router = createRouter();

      await adminApi(router).expectResponse('PATCH', '/api/config', json: const <String, dynamic>{}, status: 400);
    });

    for (final testCase in const [
      (name: 'unknown field', patch: {'nonexistent_field': 42}, field: 'nonexistent_field'),
      (name: 'read-only field', patch: {'gateway.auth_mode': 'none'}, field: 'gateway.auth_mode'),
      (name: 'invalid value (port 0)', patch: {'port': 0}, field: 'port'),
    ]) {
      test('${testCase.name} returns 400 with field error', () async {
        final json = await adminApi(
          createRouter(),
        ).expectJsonObject('PATCH', '/api/config', json: testCase.patch, status: 400);

        final errors = json['errors'] as List;
        expect(errors, isNotEmpty);
        expect((errors.first as Map)['field'], testCase.field);
      });
    }

    test('scheduling.jobs key returns 400', () async {
      final router = createRouter();
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'scheduling.jobs': []}, status: 400);

      expect(json['error']['code'], 'INVALID_INPUT');
      expect(json['error']['message'], contains('job CRUD'));
    });

    test('enabling google chat without required auth fields returns 400', () async {
      final router = createRouter();
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'channels.google_chat.enabled': true}, status: 400);

      final errors = json['errors'] as List;
      final fields = errors.map((error) => (error as Map<String, dynamic>)['field']).toSet();
      expect(
        fields,
        containsAll({
          'channels.google_chat.service_account',
          'channels.google_chat.audience.type',
          'channels.google_chat.audience.value',
        }),
      );
    });

    test('enabling github without a webhook secret returns 400', () async {
      final router = createRouter();
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'github.enabled': true}, status: 400);

      final errors = json['errors'] as List;
      expect(errors, hasLength(1));
      expect((errors.single as Map<String, dynamic>)['field'], 'github.webhook_secret');
    });

    test('enabling github succeeds when webhook secret already exists in current config', () async {
      writeConfigYaml('''
github:
  enabled: false
  webhook_secret: secret''');
      final router = createRouter();
      await adminApi(router).expectJsonObject('PATCH', '/api/config', json: {'github.enabled': true});
    });

    test('github triggers can be updated through the config API', () async {
      final router = createRouter();
      await adminApi(router).expectJsonObject(
        'PATCH',
        '/api/config',
        json: {
          'github.triggers': [
            {
              'event': 'pull_request',
              'workflow': 'code-review',
              'actions': ['opened'],
              'labels': ['needs-review'],
            },
          ],
        },
      );

      final json = await api(router).expectJsonObject('GET', '/api/config');
      final github = json['github'] as Map<String, dynamic>;
      expect((github['triggers'] as List).single, {
        'event': 'pull_request',
        'actions': ['opened'],
        'labels': ['needs-review'],
        'workflow': 'code-review',
      });
    });

    test('invalid github trigger payload returns 400', () async {
      final router = createRouter();
      await adminApi(router).expectJsonObject(
        'PATCH',
        '/api/config',
        json: {
          'github.triggers': [
            {
              'event': 'pull_request',
              'workflow': '',
              'actions': ['opened'],
            },
          ],
        },
        status: 400,
      );
    });

    test('clearing google chat service account fails when channel is already enabled', () async {
      writeConfigYaml('''
channels:
  google_chat:
    enabled: true
    service_account: /tmp/google-service-account.json
    audience:
      type: project-number
      value: "123456789"''');
      final router = createRouter();
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'channels.google_chat.service_account': '   '}, status: 400);

      final errors = json['errors'] as List;
      expect((errors.first as Map<String, dynamic>)['field'], 'channels.google_chat.service_account');
    });
  });

  group('PATCH /api/config — live fields', () {
    test('heartbeat toggle applied immediately, no restart.pending', () async {
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);
      final router = createRouter(runtime: runtime);
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'scheduling.heartbeat.enabled': false});

      expect(json['applied'], ['scheduling.heartbeat.enabled']);
      expect(json['pendingRestart'], isEmpty);

      // Verify runtime updated
      expect(runtime.heartbeatEnabled, false);

      // No restart.pending file
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), false);
    });

    test('session scope patch changes the next derived channel session key without restart', () async {
      final eventBus = EventBus();
      final liveScopeConfig = LiveScopeConfig(
        const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.shared),
      );
      final reconciler = ScopeReconciler(liveScopeConfig: liveScopeConfig);
      reconciler.subscribe(eventBus);
      addTearDown(() async {
        await reconciler.cancel();
        await eventBus.dispose();
      });

      final router = createRouter(
        config: DartclawConfig(
          sessions: SessionConfig(
            scopeConfig: const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.shared),
          ),
        ),
        eventBus: eventBus,
      );
      final manager = ChannelManager(
        queue: MessageQueue(dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async => ''),
        config: const ChannelConfig.defaults(),
        liveScopeConfig: liveScopeConfig,
      );

      final before = manager.deriveSessionKey(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'alice@s.whatsapp.net', text: 'before'),
      );
      expect(before, SessionKey.dmPerContact(peerId: 'alice@s.whatsapp.net'));

      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'sessions.dm_scope': 'shared'});
      expect(json['applied'], ['sessions.dm_scope']);
      expect(json['pendingRestart'], isEmpty);

      final after = manager.deriveSessionKey(
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'alice@s.whatsapp.net', text: 'after'),
      );
      expect(after, SessionKey.dmShared());
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), false);
    });

    test('context.warning_threshold applied immediately via ConfigChangeSubscriber', () async {
      final contextMonitor = ContextMonitor(warningThreshold: 80);
      final eventBus = EventBus();
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);
      ConfigChangeSubscriber(runtimeConfig: runtime, contextMonitor: contextMonitor).subscribe(eventBus);
      final router = createRouter(runtime: runtime, eventBus: eventBus);

      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'context.warning_threshold': 90});

      expect(json['applied'], contains('context.warning_threshold'));
      expect(json['pendingRestart'], isEmpty);
      expect(contextMonitor.warningThreshold, 90);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), false);

      await eventBus.dispose();
    });
  });

  group('PATCH /api/config — restart fields', () {
    for (final testCase in const [
      (
        field: 'context.exploration_summary_threshold',
        patch: {'context.exploration_summary_threshold': 50000},
        yamlFragment: '50000',
      ),
      (
        field: 'context.compact_instructions',
        patch: {'context.compact_instructions': 'Keep user prefs'},
        yamlFragment: 'Keep user prefs',
      ),
    ]) {
      test('${testCase.field} written to YAML and restart.pending created', () async {
        final json = await adminApi(createRouter()).expectJsonObject('PATCH', '/api/config', json: testCase.patch);

        expect(json['applied'], isEmpty);
        expect(json['pendingRestart'], contains(testCase.field));
        expect(File(configPath).readAsStringSync(), contains(testCase.yamlFragment));
        expect(File(p.join(dataDir, 'restart.pending')).existsSync(), true);
      });
    }

    test('port change written to YAML and restart.pending created', () async {
      final router = createRouter();
      final json = await adminApi(router).expectJsonObject('PATCH', '/api/config', json: {'port': 3001});

      expect(json['applied'], isEmpty);
      expect(json['pendingRestart'], ['port']);

      // Verify YAML file has new value
      final yaml = File(configPath).readAsStringSync();
      expect(yaml, contains('3001'));

      // Verify restart.pending created
      final pendingFile = File(p.join(dataDir, 'restart.pending'));
      expect(pendingFile.existsSync(), true);
      final pending = jsonDecode(pendingFile.readAsStringSync()) as Map;
      expect(pending['fields'], contains('port'));
    });
  });

  group('PATCH /api/config — mixed', () {
    test('live + restart fields both handled', () async {
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);
      final router = createRouter(runtime: runtime);
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'scheduling.heartbeat.enabled': false, 'port': 3001});

      expect(json['applied'], ['scheduling.heartbeat.enabled']);
      expect(json['pendingRestart'], ['port']);

      expect(runtime.heartbeatEnabled, false);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), true);
    });
  });

  group('PATCH /api/config — restart.pending merge', () {
    test('multiple PATCHes accumulate pending fields', () async {
      final router = createRouter();

      await adminApi(router).expectJsonObject('PATCH', '/api/config', json: {'port': 3001});
      await adminApi(router).expectJsonObject('PATCH', '/api/config', json: {'host': '0.0.0.0'});

      final pendingFile = File(p.join(dataDir, 'restart.pending'));
      final pending = jsonDecode(pendingFile.readAsStringSync()) as Map;
      final fields = (pending['fields'] as List).cast<String>();
      expect(fields, containsAll(['port', 'host']));
    });
  });

  group('Job CRUD', () {
    test('POST creates a new job', () async {
      final router = createRouter();
      final json = await api(router).expectJsonObject(
        'POST',
        '/api/scheduling/jobs',
        json: {'name': 'test-job', 'schedule': '0 7 * * *', 'prompt': 'Hello world', 'delivery': 'announce'},
        status: 201,
      );

      expect(json['job']['name'], 'test-job');
      expect(json['pendingRestart'], true);

      // Verify restart.pending
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), true);
    });

    test('POST with duplicate name returns 409', () async {
      final jobs = [
        {'name': 'existing', 'schedule': '0 7 * * *', 'prompt': 'hi', 'delivery': 'announce'},
      ];
      writeJobsToYaml(jobs);
      final config = DartclawConfig(scheduling: SchedulingConfig(jobs: jobs));
      final router = createRouter(config: config);
      await api(router).expectResponse(
        'POST',
        '/api/scheduling/jobs',
        json: {'name': 'existing', 'schedule': '0 8 * * *', 'prompt': 'hi', 'delivery': 'announce'},
        status: 409,
      );
    });

    test('POST with missing required field returns 400', () async {
      final router = createRouter();
      await api(router).expectResponse(
        'POST',
        '/api/scheduling/jobs',
        json: {
          'name': 'test-job',
          // missing schedule, prompt, delivery
        },
        status: 400,
      );
    });

    test('POST with invalid cron returns 400', () async {
      final router = createRouter();
      final json = await api(router).expectJsonObject(
        'POST',
        '/api/scheduling/jobs',
        json: {'name': 'test-job', 'schedule': 'not-a-cron', 'prompt': 'Hello', 'delivery': 'announce'},
        status: 400,
      );

      expect(json['error']['message'], contains('cron'));
    });

    test('PUT updates existing job', () async {
      final jobs = [
        {'name': 'my-job', 'schedule': '0 7 * * *', 'prompt': 'hi', 'delivery': 'announce'},
      ];
      writeJobsToYaml(jobs);
      final config = DartclawConfig(scheduling: SchedulingConfig(jobs: jobs));
      final router = createRouter(config: config);
      final json = await api(
        router,
      ).expectJsonObject('PUT', '/api/scheduling/jobs/my-job', json: {'schedule': '0 8 * * *'});

      expect(json['job']['schedule'], '0 8 * * *');
      expect(json['job']['name'], 'my-job');
      expect(json['pendingRestart'], true);
    });

    test('PUT non-existent job returns 404', () async {
      final router = createRouter();
      await api(
        router,
      ).expectResponse('PUT', '/api/scheduling/jobs/nonexistent', json: {'schedule': '0 8 * * *'}, status: 404);
    });

    test('DELETE removes job', () async {
      final jobs = [
        {'name': 'my-job', 'schedule': '0 7 * * *', 'prompt': 'hi', 'delivery': 'announce'},
      ];
      writeJobsToYaml(jobs);
      final config = DartclawConfig(scheduling: SchedulingConfig(jobs: jobs));
      final router = createRouter(config: config);
      final json = await api(router).expectJsonObject('DELETE', '/api/scheduling/jobs/my-job');

      expect(json['deleted'], true);
      expect(json['pendingRestart'], true);
    });

    test('DELETE non-existent job returns 404', () async {
      final router = createRouter();
      await api(router).expectResponse('DELETE', '/api/scheduling/jobs/nonexistent', status: 404);
    });
  });

  /// Writes task jobs to the YAML config file so [ConfigWriter.readSchedulingJobs]
  /// returns them (tests that need pre-existing task jobs must call this).
  void writeTaskJobsToYaml(List<Map<String, dynamic>> jobs) {
    final buffer = StringBuffer();
    buffer.writeln('port: 3000');
    buffer.writeln('host: localhost');
    buffer.writeln('scheduling:');
    buffer.writeln('  heartbeat:');
    buffer.writeln('    enabled: true');
    buffer.writeln('    interval_minutes: 30');
    buffer.writeln('  jobs:');
    for (final j in jobs) {
      buffer.writeln('  - id: ${j['id']}');
      buffer.writeln('    type: task');
      buffer.writeln('    schedule: "${j['schedule']}"');
      buffer.writeln('    enabled: ${j['enabled'] ?? true}');
      if (j['task'] != null) {
        final t = j['task'] as Map<String, dynamic>;
        buffer.writeln('    task:');
        buffer.writeln('      title: "${t['title']}"');
        buffer.writeln('      description: "${t['description']}"');
        buffer.writeln('      type: ${t['type']}');
      }
    }
    buffer.writeln('workspace:');
    buffer.writeln('  git_sync:');
    buffer.writeln('    enabled: true');
    buffer.writeln('    push_enabled: true');
    File(configPath).writeAsStringSync(buffer.toString());
  }

  group('Task Job CRUD via scheduling.jobs', () {
    test('POST /api/scheduling/tasks creates entry under scheduling.jobs', () async {
      final router = createRouter();
      final json = await api(router).expectJsonObject(
        'POST',
        '/api/scheduling/tasks',
        json: {
          'id': 'daily-review',
          'schedule': '0 9 * * 1-5',
          'title': 'Daily review',
          'description': 'Review open items',
          'type': 'research',
        },
        status: 201,
      );

      expect(json['task']['id'], 'daily-review');
      expect(json['task']['type'], 'task');
      expect(json['pendingRestart'], true);

      // Verify restart.pending written with scheduling.jobs
      final pendingFile = File(p.join(dataDir, 'restart.pending'));
      expect(pendingFile.existsSync(), true);
      final pending = jsonDecode(pendingFile.readAsStringSync()) as Map;
      expect(pending['fields'], contains('scheduling.jobs'));
      expect(pending['fields'], isNot(contains('automation.scheduled_tasks')));
    });

    test('POST /api/scheduling/tasks with duplicate id returns 409', () async {
      writeTaskJobsToYaml([
        {
          'id': 'existing-task',
          'schedule': '0 9 * * *',
          'task': {'title': 'Existing', 'description': 'Desc', 'type': 'research'},
        },
      ]);
      final router = createRouter();
      await api(router).expectResponse(
        'POST',
        '/api/scheduling/tasks',
        json: {
          'id': 'existing-task',
          'schedule': '0 10 * * *',
          'title': 'Another',
          'description': 'Desc',
          'type': 'research',
        },
        status: 409,
      );
    });

    test('PUT /api/scheduling/tasks/<id> updates task job in scheduling.jobs', () async {
      writeTaskJobsToYaml([
        {
          'id': 'my-task',
          'schedule': '0 9 * * *',
          'task': {'title': 'Old title', 'description': 'Desc', 'type': 'research'},
        },
      ]);
      final router = createRouter();
      final json = await api(
        router,
      ).expectJsonObject('PUT', '/api/scheduling/tasks/my-task', json: {'enabled': false, 'title': 'New title'});

      expect(json['task']['enabled'], false);
      expect(json['task']['task']['title'], 'New title');
      expect(json['pendingRestart'], true);

      // Verify restart.pending uses scheduling.jobs key
      final pendingFile = File(p.join(dataDir, 'restart.pending'));
      final pending = jsonDecode(pendingFile.readAsStringSync()) as Map;
      expect(pending['fields'], contains('scheduling.jobs'));
    });

    test('PUT /api/scheduling/tasks/<id> returns 404 for missing task', () async {
      final router = createRouter();
      await api(
        router,
      ).expectResponse('PUT', '/api/scheduling/tasks/nonexistent', json: {'enabled': false}, status: 404);
    });

    test('DELETE /api/scheduling/tasks/<id> removes from scheduling.jobs', () async {
      writeTaskJobsToYaml([
        {
          'id': 'removable-task',
          'schedule': '0 9 * * *',
          'task': {'title': 'Remove me', 'description': 'Desc', 'type': 'automation'},
        },
      ]);
      final router = createRouter();
      final json = await api(router).expectJsonObject('DELETE', '/api/scheduling/tasks/removable-task');

      expect(json['deleted'], true);
      expect(json['pendingRestart'], true);

      // Verify restart.pending uses scheduling.jobs key
      final pendingFile = File(p.join(dataDir, 'restart.pending'));
      final pending = jsonDecode(pendingFile.readAsStringSync()) as Map;
      expect(pending['fields'], contains('scheduling.jobs'));
    });

    test('DELETE /api/scheduling/tasks/<id> returns 404 for missing task', () async {
      final router = createRouter();
      await api(router).expectResponse('DELETE', '/api/scheduling/tasks/nonexistent', status: 404);
    });

    test('POST /api/scheduling/jobs with type: task does not require delivery', () async {
      final router = createRouter();
      final json = await api(router).expectJsonObject(
        'POST',
        '/api/scheduling/jobs',
        json: {
          'name': 'scheduled-coding-task',
          'type': 'task',
          'schedule': '0 10 * * *',
          'task': {'title': 'Coding task', 'description': 'Do some coding', 'task_type': 'coding'},
        },
        status: 201,
      );

      expect(json['job']['name'], 'scheduled-coding-task');
      expect(json['job']['type'], 'task');
      // delivery should not be present for task-type jobs
      expect(json['job'].containsKey('delivery'), isFalse);
    });

    test('PUT /api/scheduling/jobs/<id> finds a job by id field', () async {
      // Write a job that uses 'id' instead of 'name'
      File(configPath).writeAsStringSync('''
port: 3000
host: localhost
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs:
  - id: job-with-id
    type: task
    schedule: "0 9 * * *"
    enabled: true
    task:
      title: Original
      description: Desc
      type: research
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
      final router = createRouter();
      final json = await api(
        router,
      ).expectJsonObject('PUT', '/api/scheduling/jobs/job-with-id', json: {'enabled': false});

      expect(json['job']['enabled'], false);
    });
  });

  group('GET after PATCH — round-trip', () {
    test('restart.pending reflected in _meta after PATCH', () async {
      final router = createRouter();

      // PATCH a restart field
      await adminApi(router).expectJsonObject('PATCH', '/api/config', json: {'port': 3001});

      // GET should show restartPending = true
      final json = await api(router).expectJsonObject('GET', '/api/config');
      final meta = json['_meta'] as Map<String, dynamic>;

      expect(meta['restartPending'], true);
      expect(meta['pendingFields'], contains('port'));
    });
  });

  group('DM Pairing API', () {
    test('GET returns empty pending list when no pairings', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final json = await api(router).expectJsonObject('GET', '/api/channels/whatsapp/dm-pairing');

      expect(json['pending'], isEmpty);
      expect(json['total'], 0);
    });

    test('GET returns pending pairings with correct fields', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      ctrl.createPairing('+15551234567', displayName: 'Alice');
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final json = await api(router).expectJsonObject('GET', '/api/channels/whatsapp/dm-pairing');

      expect(json['total'], 1);
      final pending = json['pending'] as List;
      expect(pending.first['senderId'], '+15551234567');
      expect(pending.first['displayName'], 'Alice');
      expect(pending.first['code'], isNotEmpty);
      expect(pending.first['remainingSeconds'], greaterThan(0));
    });

    test('confirm adds sender to allowlist and persists', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final pairing = ctrl.createPairing('+15551234567', displayName: 'Alice')!;
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final json = await api(
        router,
      ).expectJsonObject('POST', '/api/channels/whatsapp/dm-pairing/confirm', json: {'code': pairing.code});

      expect(json['confirmed'], true);
      expect(json['senderId'], '+15551234567');
      expect(ctrl.isAllowed('+15551234567'), isTrue);
      expect(ctrl.pendingPairings, isEmpty);
    });

    test('confirm with expired/unknown code returns 404', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final router = createRouterWithPairing(dmAccessController: ctrl);
      await api(
        router,
      ).expectResponse('POST', '/api/channels/whatsapp/dm-pairing/confirm', json: {'code': 'INVALID!'}, status: 404);
    });

    test('reject removes pairing without adding to allowlist', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final pairing = ctrl.createPairing('+15551234567')!;
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final json = await api(
        router,
      ).expectJsonObject('POST', '/api/channels/whatsapp/dm-pairing/reject', json: {'code': pairing.code});

      expect(json['rejected'], true);
      expect(ctrl.isAllowed('+15551234567'), isFalse);
      expect(ctrl.pendingPairings, isEmpty);
    });

    test('reject with unknown code returns 404', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final router = createRouterWithPairing(dmAccessController: ctrl);
      await api(
        router,
      ).expectResponse('POST', '/api/channels/whatsapp/dm-pairing/reject', json: {'code': 'NONEXIST'}, status: 404);
    });

    test('GET on non-configured channel returns 404', () async {
      final router = createRouter();

      await api(router).expectResponse('GET', '/api/channels/whatsapp/dm-pairing', status: 404);
    });

    test('pairing-counts returns counts for both channels', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      ctrl.createPairing('+15551234567');
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final json = await api(router).expectJsonObject('GET', '/api/channels/pairing-counts');

      expect(json['whatsapp'], 1);
      expect(json['signal'], 0);
    });
  });

  // ---------------------------------------------------------------------------
  // G4 — Three-tier PATCH partitioning + hot-reload
  // ---------------------------------------------------------------------------

  group('G4 three-tier PATCH partitioning', () {
    /// Creates a router wired with a real [ConfigNotifier].
    Router createRouterWithNotifier(ConfigNotifier notifier, {DartclawConfig? config}) {
      final cfg = config ?? const DartclawConfig.defaults();
      final rc = RuntimeConfig(
        heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
        gitSyncEnabled: cfg.workspace.gitSyncEnabled,
        gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
      );
      final writer = ConfigWriter(configPath: configPath);
      final validator = const ConfigValidator();
      final bus = EventBus();
      ConfigChangeSubscriber(runtimeConfig: rc).subscribe(bus);

      return configApiRoutes(
        config: cfg,
        writer: writer,
        validator: validator,
        runtimeConfig: rc,
        dataDir: dataDir,
        eventBus: bus,
        configNotifier: notifier,
      );
    }

    test('PATCH reloadable field returns in applied, reload() called, no restart.pending', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final router = createRouterWithNotifier(notifier);

      // concurrency.max_parallel_turns is reloadable
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'concurrency.max_parallel_turns': 4});

      expect(json['applied'], contains('concurrency.max_parallel_turns'));
      expect(json['pendingRestart'], isEmpty);

      // restart.pending file must NOT exist
      final restartFile = File(p.join(dataDir, 'restart.pending'));
      expect(restartFile.existsSync(), isFalse);
    });

    test('PATCH restart field writes restart.pending and returns in pendingRestart', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final router = createRouterWithNotifier(notifier);

      // server.port is restart-required
      final json = await adminApi(router).expectJsonObject('PATCH', '/api/config', json: {'port': 8080});

      expect(json['pendingRestart'], contains('port'));
      expect(json['applied'], isEmpty);

      final restartFile = File(p.join(dataDir, 'restart.pending'));
      expect(restartFile.existsSync(), isTrue);
    });

    test('mixed PATCH: reloadable in applied, restart field in pendingRestart', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final router = createRouterWithNotifier(notifier);

      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'concurrency.max_parallel_turns': 4, 'port': 9090});

      expect(json['applied'], contains('concurrency.max_parallel_turns'));
      expect(json['pendingRestart'], contains('port'));
      expect(json['pendingRestart'], isNot(contains('concurrency.max_parallel_turns')));
    });

    test('workflow model shorthand patch also writes the sibling provider field', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final router = createRouterWithNotifier(notifier);

      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'workflow.defaults.reviewer.model': 'codex/gpt-5-codex'});

      expect(json['pendingRestart'], contains('workflow.defaults.reviewer.model'));
      expect(json['pendingRestart'], contains('workflow.defaults.reviewer.provider'));

      final written = File(configPath).readAsStringSync();
      expect(written, contains('reviewer:'));
      expect(written, contains('provider: codex'));
      expect(written, contains('model: gpt-5-codex'));
    });

    test('agent model shorthand patch also writes agent.provider', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final router = createRouterWithNotifier(notifier);

      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'agent.model': 'codex/gpt-5.4'});

      expect(json['pendingRestart'], contains('agent.model'));
      expect(json['pendingRestart'], contains('agent.provider'));

      final written = File(configPath).readAsStringSync();
      expect(written, contains('agent:'));
      expect(written, contains('provider: codex'));
      expect(written, contains('model: gpt-5.4'));
    });

    test('ConfigNotifier.reload() failure falls back to pendingRestart', () async {
      // Use _ThrowingConfigNotifier to simulate a reload() failure.
      final throwingRouter = _buildRouterWithThrowingNotifier(configPath, dataDir);

      final json = await adminApi(
        throwingRouter,
      ).expectJsonObject('PATCH', '/api/config', json: {'concurrency.max_parallel_turns': 4});

      // Field written to YAML but reload failed → falls back to pendingRestart
      expect(json['applied'], isEmpty);
      expect(json['pendingRestart'], contains('concurrency.max_parallel_turns'));

      final restartFile = File(p.join(dataDir, 'restart.pending'));
      expect(restartFile.existsSync(), isTrue);
    });

    test('PATCH live field fires ConfigChangedEvent and returns in applied', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final bus = EventBus();
      final rc = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: false, gitSyncPushEnabled: false);
      ConfigChangeSubscriber(runtimeConfig: rc).subscribe(bus);

      ConfigChangedEvent? captured;
      bus.on<ConfigChangedEvent>().listen((e) => captured = e);

      final router = configApiRoutes(
        config: const DartclawConfig.defaults(),
        writer: ConfigWriter(configPath: configPath),
        validator: const ConfigValidator(),
        runtimeConfig: rc,
        dataDir: dataDir,
        eventBus: bus,
        configNotifier: notifier,
      );

      // scheduling.heartbeat.enabled is a live field
      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'scheduling.heartbeat.enabled': false});

      expect(json['applied'], contains('scheduling.heartbeat.enabled'));
      expect(json['pendingRestart'], isEmpty);
      expect(captured, isNotNull);
      expect(captured!.changedKeys, contains('scheduling.heartbeat.enabled'));
    });

    test('PATCH with no notifier wired treats reloadable as pendingRestart', () async {
      // createRouter() does not wire a ConfigNotifier
      final router = createRouter();

      final json = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'concurrency.max_parallel_turns': 4});

      expect(json['applied'], isEmpty);
      expect(json['pendingRestart'], contains('concurrency.max_parallel_turns'));
    });
  });

  group('R02 hot-reload SSE continuity', () {
    Router createRouterWithSse({
      ConfigNotifier? configNotifier,
      RestartService? restartService,
      required SseBroadcast sseBroadcast,
    }) {
      final cfg = const DartclawConfig.defaults();
      final rc = RuntimeConfig(
        heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
        gitSyncEnabled: cfg.workspace.gitSyncEnabled,
        gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
      );
      final writer = ConfigWriter(configPath: configPath);
      return configApiRoutes(
        config: cfg,
        writer: writer,
        validator: const ConfigValidator(),
        runtimeConfig: rc,
        dataDir: dataDir,
        configNotifier: configNotifier,
        restartService: restartService,
        sseBroadcast: sseBroadcast,
      );
    }

    test('pre-existing /api/events subscriber survives reloadable PATCH and receives a later broadcast', () async {
      final sseBroadcast = SseBroadcast();
      addTearDown(sseBroadcast.dispose);

      final router = createRouterWithSse(
        configNotifier: ConfigNotifier(const DartclawConfig.defaults()),
        sseBroadcast: sseBroadcast,
      );

      final sseResponse = await api(router).expectResponse('GET', '/api/events', status: 200);
      expect(sseResponse.headers['content-type'], 'text/event-stream');

      final iterator = StreamIterator(sseResponse.read().transform(utf8.decoder));
      addTearDown(iterator.cancel);

      final patchJson = await adminApi(
        router,
      ).expectJsonObject('PATCH', '/api/config', json: {'concurrency.max_parallel_turns': 4});
      expect(patchJson['applied'], contains('concurrency.max_parallel_turns'));
      expect(patchJson['pendingRestart'], isEmpty);

      sseBroadcast.broadcast('context_warning', {'message': 'post-reload'});

      final frame = await nextSseFrame(iterator);
      expect(frame, contains('event: context_warning'));
      expect(frame, contains('"message":"post-reload"'));
    });

    test(
      'restart-required PATCH keeps pendingRestart and /api/events receives server_restart on restart trigger',
      () async {
        final sseBroadcast = SseBroadcast();
        addTearDown(sseBroadcast.dispose);

        final restartService = RestartService(
          turns: FakeTurnManager(),
          exit: (_) {},
          broadcastSse: sseBroadcast.broadcast,
          writeRestartPending: writeRestartPending,
          dataDir: dataDir,
        );

        final router = createRouterWithSse(restartService: restartService, sseBroadcast: sseBroadcast);

        final sseResponse = await api(router).expectResponse('GET', '/api/events', status: 200);
        final iterator = StreamIterator(sseResponse.read().transform(utf8.decoder));
        addTearDown(iterator.cancel);

        final patchJson = await adminApi(router).expectJsonObject('PATCH', '/api/config', json: {'port': 3001});
        expect(patchJson['applied'], isEmpty);
        expect(patchJson['pendingRestart'], contains('port'));

        final configJson = await api(router).expectJsonObject('GET', '/api/config');
        final meta = configJson['_meta'] as Map<String, dynamic>;
        expect(meta['restartPending'], true);
        expect(meta['pendingFields'], contains('port'));

        final restartJson = await api(router).expectJsonObject('POST', '/api/system/restart');
        expect(restartJson['status'], 'restarting');

        final frame = await nextSseFrame(iterator);
        expect(frame, contains('event: server_restart'));
        expect(frame, contains('"drainDeadlineSeconds":30'));
      },
    );
  });
}

// --- Fakes ---

/// Builds a [configApiRoutes] router whose [ConfigNotifier] throws on [reload].
/// Used to test the reloadable-fallback-to-pendingRestart path.
Router _buildRouterWithThrowingNotifier(String configPath, String dataDir) {
  final cfg = const DartclawConfig.defaults();
  final rc = RuntimeConfig(
    heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
    gitSyncEnabled: cfg.workspace.gitSyncEnabled,
    gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
  );
  return configApiRoutes(
    config: cfg,
    writer: ConfigWriter(configPath: configPath),
    validator: const ConfigValidator(),
    runtimeConfig: rc,
    dataDir: dataDir,
    configNotifier: _ThrowingConfigNotifier(cfg),
  );
}

/// [ConfigNotifier] subclass whose [reload] always throws.
class _ThrowingConfigNotifier extends ConfigNotifier {
  _ThrowingConfigNotifier(super.initial);

  @override
  ConfigDelta? reload(DartclawConfig newConfig) {
    throw StateError('simulated reload failure');
  }
}
