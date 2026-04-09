import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_api_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();

    // Write a minimal valid YAML config
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
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

    // Write channel config to YAML so allowlist persistence works
    File(configPath).writeAsStringSync('''
port: 3000
host: localhost
channels:
  whatsapp:
    enabled: true
    dm_access: pairing
    dm_allowlist: []
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');

    final waChannel = WhatsAppChannel(
      gowa: _FakeGowaManager(),
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

  Future<Response> get(Router router, String path) {
    final request = Request('GET', Uri.parse('http://localhost$path'));
    return router.call(request);
  }

  Future<Response> patch(Router router, String path, Map<String, dynamic> body) {
    final request = Request(
      'PATCH',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
    return router.call(request);
  }

  Future<Response> post(Router router, String path, Map<String, dynamic> body) {
    final request = Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
    return router.call(request);
  }

  Future<Response> put(Router router, String path, Map<String, dynamic> body) {
    final request = Request(
      'PUT',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
    return router.call(request);
  }

  Future<Response> delete(Router router, String path) {
    final request = Request('DELETE', Uri.parse('http://localhost$path'));
    return router.call(request);
  }

  Future<Map<String, dynamic>> readJson(Response response) async {
    final body = await response.readAsString();
    return jsonDecode(body) as Map<String, dynamic>;
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
      final response = await get(router, '/api/config');

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['port'], 3000);
      expect(json['host'], 'localhost');
      expect(json.containsKey('_meta'), isTrue);
    });

    test('contains _meta.fields map', () async {
      final router = createRouter();
      final response = await get(router, '/api/config');
      final json = await readJson(response);

      final meta = json['_meta'] as Map<String, dynamic>;
      expect(meta.containsKey('fields'), isTrue);
      final fields = meta['fields'] as Map<String, dynamic>;
      expect(fields.containsKey('port'), isTrue);
      expect(fields.containsKey('scheduling.heartbeat.enabled'), isTrue);
    });

    test('contains _meta.lastBackup (null when no backup)', () async {
      final router = createRouter();
      final response = await get(router, '/api/config');
      final json = await readJson(response);

      final meta = json['_meta'] as Map<String, dynamic>;
      expect(meta['lastBackup'], isNull);
    });

    test('contains _meta.restartPending (false when no pending file)', () async {
      final router = createRouter();
      final response = await get(router, '/api/config');
      final json = await readJson(response);

      final meta = json['_meta'] as Map<String, dynamic>;
      expect(meta['restartPending'], false);
      expect(meta['pendingFields'], isEmpty);
    });

    test('gateway.token is masked', () async {
      // Write gateway token into YAML so fresh config load picks it up
      File(configPath).writeAsStringSync('''
port: 3000
host: localhost
gateway:
  token: secret-token
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
      final router = createRouter(config: const DartclawConfig(gateway: GatewayConfig(token: 'secret-token')));
      final response = await get(router, '/api/config');
      final json = await readJson(response);

      final gateway = json['gateway'] as Map<String, dynamic>;
      expect(gateway['token'], '***');
    });

    test('google chat inline service account is redacted in API response', () async {
      File(configPath).writeAsStringSync('''
port: 3000
host: localhost
channels:
  google_chat:
    enabled: true
    service_account: '{"type":"service_account","client_email":"chat-bot@example.iam.gserviceaccount.com","private_key":"secret"}'
    audience:
      type: project-number
      value: '123456789'
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
      final router = createRouter();
      final response = await get(router, '/api/config');
      final json = await readJson(response);

      final channels = json['channels'] as Map<String, dynamic>;
      final googleChat = channels['googleChat'] as Map<String, dynamic>;
      expect(googleChat['serviceAccount'], 'chat-bot@example.iam.gserviceaccount.com');
    });

    test('whatsapp config is serialized from parsed typed config', () async {
      File(configPath).writeAsStringSync('''
port: 3000
host: localhost
channels:
  whatsapp:
    enabled: nope
    dm_access: invalid
    group_access: invalid
    require_mention: invalid
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
      final router = createRouter();
      final response = await get(router, '/api/config');
      final json = await readJson(response);

      final channels = json['channels'] as Map<String, dynamic>;
      final whatsapp = channels['whatsapp'] as Map<String, dynamic>;
      expect(whatsapp['enabled'], isFalse);
      expect(whatsapp['dmAccess'], 'pairing');
      expect(whatsapp['groupAccess'], 'disabled');
      expect(whatsapp['requireMention'], isTrue);
    });
  });

  group('PATCH /api/config — validation', () {
    test('empty body returns 400', () async {
      final router = createRouter();
      final request = Request(
        'PATCH',
        Uri.parse('http://localhost/api/config'),
        body: '{}',
        headers: {'content-type': 'application/json'},
      );
      final response = await router.call(request);
      expect(response.statusCode, 400);
    });

    test('unknown field returns 400 with error', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'nonexistent_field': 42});
      expect(response.statusCode, 400);

      final json = await readJson(response);
      final errors = json['errors'] as List;
      expect(errors, hasLength(1));
      expect((errors[0] as Map)['field'], 'nonexistent_field');
    });

    test('read-only field returns 400', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'gateway.auth_mode': 'none'});
      expect(response.statusCode, 400);

      final json = await readJson(response);
      final errors = json['errors'] as List;
      expect(errors, isNotEmpty);
      expect((errors[0] as Map)['field'], 'gateway.auth_mode');
    });

    test('invalid value (port 0) returns 400', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'port': 0});
      expect(response.statusCode, 400);

      final json = await readJson(response);
      final errors = json['errors'] as List;
      expect(errors, hasLength(1));
      expect((errors[0] as Map)['field'], 'port');
    });

    test('scheduling.jobs key returns 400', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'scheduling.jobs': []});
      expect(response.statusCode, 400);

      final json = await readJson(response);
      expect(json['error']['code'], 'INVALID_INPUT');
      expect(json['error']['message'], contains('job CRUD'));
    });

    test('enabling google chat without required auth fields returns 400', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'channels.google_chat.enabled': true});
      expect(response.statusCode, 400);

      final json = await readJson(response);
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

    test('clearing google chat service account fails when channel is already enabled', () async {
      File(configPath).writeAsStringSync('''
port: 3000
host: localhost
channels:
  google_chat:
    enabled: true
    service_account: /tmp/google-service-account.json
    audience:
      type: project-number
      value: '123456789'
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');
      final router = createRouter();
      final response = await patch(router, '/api/config', {'channels.google_chat.service_account': '   '});
      expect(response.statusCode, 400);

      final json = await readJson(response);
      final errors = json['errors'] as List;
      expect((errors.first as Map<String, dynamic>)['field'], 'channels.google_chat.service_account');
    });
  });

  group('PATCH /api/config — live fields', () {
    test('heartbeat toggle applied immediately, no restart.pending', () async {
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true);
      final router = createRouter(runtime: runtime);
      final response = await patch(router, '/api/config', {'scheduling.heartbeat.enabled': false});

      expect(response.statusCode, 200);
      final json = await readJson(response);
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

      final response = await patch(router, '/api/config', {'sessions.dm_scope': 'shared'});
      expect(response.statusCode, 200);
      final json = await readJson(response);
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

      final response = await patch(router, '/api/config', {'context.warning_threshold': 90});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['applied'], contains('context.warning_threshold'));
      expect(json['pendingRestart'], isEmpty);
      expect(contextMonitor.warningThreshold, 90);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), false);

      await eventBus.dispose();
    });
  });

  group('PATCH /api/config — restart fields', () {
    test('exploration_summary_threshold written to YAML and restart.pending created', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'context.exploration_summary_threshold': 50000});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['applied'], isEmpty);
      expect(json['pendingRestart'], contains('context.exploration_summary_threshold'));

      final yaml = File(configPath).readAsStringSync();
      expect(yaml, contains('50000'));
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), true);
    });

    test('compact_instructions written to YAML and restart.pending created', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'context.compact_instructions': 'Keep user prefs'});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['applied'], isEmpty);
      expect(json['pendingRestart'], contains('context.compact_instructions'));

      final yaml = File(configPath).readAsStringSync();
      expect(yaml, contains('Keep user prefs'));
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), true);
    });

    test('port change written to YAML and restart.pending created', () async {
      final router = createRouter();
      final response = await patch(router, '/api/config', {'port': 3001});

      expect(response.statusCode, 200);
      final json = await readJson(response);
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
      final response = await patch(router, '/api/config', {'scheduling.heartbeat.enabled': false, 'port': 3001});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['applied'], ['scheduling.heartbeat.enabled']);
      expect(json['pendingRestart'], ['port']);

      expect(runtime.heartbeatEnabled, false);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), true);
    });
  });

  group('PATCH /api/config — restart.pending merge', () {
    test('multiple PATCHes accumulate pending fields', () async {
      final router = createRouter();

      await patch(router, '/api/config', {'port': 3001});
      await patch(router, '/api/config', {'host': '0.0.0.0'});

      final pendingFile = File(p.join(dataDir, 'restart.pending'));
      final pending = jsonDecode(pendingFile.readAsStringSync()) as Map;
      final fields = (pending['fields'] as List).cast<String>();
      expect(fields, containsAll(['port', 'host']));
    });
  });

  group('Job CRUD', () {
    test('POST creates a new job', () async {
      final router = createRouter();
      final response = await post(router, '/api/scheduling/jobs', {
        'name': 'test-job',
        'schedule': '0 7 * * *',
        'prompt': 'Hello world',
        'delivery': 'announce',
      });

      expect(response.statusCode, 201);
      final json = await readJson(response);
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
      final response = await post(router, '/api/scheduling/jobs', {
        'name': 'existing',
        'schedule': '0 8 * * *',
        'prompt': 'hi',
        'delivery': 'announce',
      });

      expect(response.statusCode, 409);
    });

    test('POST with missing required field returns 400', () async {
      final router = createRouter();
      final response = await post(router, '/api/scheduling/jobs', {
        'name': 'test-job',
        // missing schedule, prompt, delivery
      });

      expect(response.statusCode, 400);
    });

    test('POST with invalid cron returns 400', () async {
      final router = createRouter();
      final response = await post(router, '/api/scheduling/jobs', {
        'name': 'test-job',
        'schedule': 'not-a-cron',
        'prompt': 'Hello',
        'delivery': 'announce',
      });

      expect(response.statusCode, 400);
      final json = await readJson(response);
      expect(json['error']['message'], contains('cron'));
    });

    test('PUT updates existing job', () async {
      final jobs = [
        {'name': 'my-job', 'schedule': '0 7 * * *', 'prompt': 'hi', 'delivery': 'announce'},
      ];
      writeJobsToYaml(jobs);
      final config = DartclawConfig(scheduling: SchedulingConfig(jobs: jobs));
      final router = createRouter(config: config);
      final response = await put(router, '/api/scheduling/jobs/my-job', {'schedule': '0 8 * * *'});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['job']['schedule'], '0 8 * * *');
      expect(json['job']['name'], 'my-job');
      expect(json['pendingRestart'], true);
    });

    test('PUT non-existent job returns 404', () async {
      final router = createRouter();
      final response = await put(router, '/api/scheduling/jobs/nonexistent', {'schedule': '0 8 * * *'});

      expect(response.statusCode, 404);
    });

    test('DELETE removes job', () async {
      final jobs = [
        {'name': 'my-job', 'schedule': '0 7 * * *', 'prompt': 'hi', 'delivery': 'announce'},
      ];
      writeJobsToYaml(jobs);
      final config = DartclawConfig(scheduling: SchedulingConfig(jobs: jobs));
      final router = createRouter(config: config);
      final response = await delete(router, '/api/scheduling/jobs/my-job');

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['deleted'], true);
      expect(json['pendingRestart'], true);
    });

    test('DELETE non-existent job returns 404', () async {
      final router = createRouter();
      final response = await delete(router, '/api/scheduling/jobs/nonexistent');

      expect(response.statusCode, 404);
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
      final response = await post(router, '/api/scheduling/tasks', {
        'id': 'daily-review',
        'schedule': '0 9 * * 1-5',
        'title': 'Daily review',
        'description': 'Review open items',
        'type': 'research',
      });

      expect(response.statusCode, 201);
      final json = await readJson(response);
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
      final response = await post(router, '/api/scheduling/tasks', {
        'id': 'existing-task',
        'schedule': '0 10 * * *',
        'title': 'Another',
        'description': 'Desc',
        'type': 'research',
      });

      expect(response.statusCode, 409);
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
      final response = await put(router, '/api/scheduling/tasks/my-task', {'enabled': false, 'title': 'New title'});

      expect(response.statusCode, 200);
      final json = await readJson(response);
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
      final response = await put(router, '/api/scheduling/tasks/nonexistent', {'enabled': false});

      expect(response.statusCode, 404);
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
      final response = await delete(router, '/api/scheduling/tasks/removable-task');

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['deleted'], true);
      expect(json['pendingRestart'], true);

      // Verify restart.pending uses scheduling.jobs key
      final pendingFile = File(p.join(dataDir, 'restart.pending'));
      final pending = jsonDecode(pendingFile.readAsStringSync()) as Map;
      expect(pending['fields'], contains('scheduling.jobs'));
    });

    test('DELETE /api/scheduling/tasks/<id> returns 404 for missing task', () async {
      final router = createRouter();
      final response = await delete(router, '/api/scheduling/tasks/nonexistent');

      expect(response.statusCode, 404);
    });

    test('POST /api/scheduling/jobs with type: task does not require delivery', () async {
      final router = createRouter();
      final response = await post(router, '/api/scheduling/jobs', {
        'name': 'scheduled-coding-task',
        'type': 'task',
        'schedule': '0 10 * * *',
        'task': {'title': 'Coding task', 'description': 'Do some coding', 'task_type': 'coding'},
      });

      expect(response.statusCode, 201);
      final json = await readJson(response);
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
      final response = await put(router, '/api/scheduling/jobs/job-with-id', {'enabled': false});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['job']['enabled'], false);
    });
  });

  group('GET after PATCH — round-trip', () {
    test('restart.pending reflected in _meta after PATCH', () async {
      final router = createRouter();

      // PATCH a restart field
      await patch(router, '/api/config', {'port': 3001});

      // GET should show restartPending = true
      final response = await get(router, '/api/config');
      final json = await readJson(response);
      final meta = json['_meta'] as Map<String, dynamic>;

      expect(meta['restartPending'], true);
      expect(meta['pendingFields'], contains('port'));
    });
  });

  group('DM Pairing API', () {
    test('GET returns empty pending list when no pairings', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final response = await get(router, '/api/channels/whatsapp/dm-pairing');

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['pending'], isEmpty);
      expect(json['total'], 0);
    });

    test('GET returns pending pairings with correct fields', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      ctrl.createPairing('+15551234567', displayName: 'Alice');
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final response = await get(router, '/api/channels/whatsapp/dm-pairing');

      expect(response.statusCode, 200);
      final json = await readJson(response);
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
      final response = await post(router, '/api/channels/whatsapp/dm-pairing/confirm', {'code': pairing.code});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['confirmed'], true);
      expect(json['senderId'], '+15551234567');
      expect(ctrl.isAllowed('+15551234567'), isTrue);
      expect(ctrl.pendingPairings, isEmpty);
    });

    test('confirm with expired/unknown code returns 404', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final response = await post(router, '/api/channels/whatsapp/dm-pairing/confirm', {'code': 'INVALID!'});

      expect(response.statusCode, 404);
    });

    test('reject removes pairing without adding to allowlist', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final pairing = ctrl.createPairing('+15551234567')!;
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final response = await post(router, '/api/channels/whatsapp/dm-pairing/reject', {'code': pairing.code});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['rejected'], true);
      expect(ctrl.isAllowed('+15551234567'), isFalse);
      expect(ctrl.pendingPairings, isEmpty);
    });

    test('reject with unknown code returns 404', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final response = await post(router, '/api/channels/whatsapp/dm-pairing/reject', {'code': 'NONEXIST'});

      expect(response.statusCode, 404);
    });

    test('GET on non-configured channel returns 404', () async {
      final router = createRouter();
      final response = await get(router, '/api/channels/whatsapp/dm-pairing');

      expect(response.statusCode, 404);
    });

    test('pairing-counts returns counts for both channels', () async {
      final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      ctrl.createPairing('+15551234567');
      final router = createRouterWithPairing(dmAccessController: ctrl);
      final response = await get(router, '/api/channels/pairing-counts');

      expect(response.statusCode, 200);
      final json = await readJson(response);
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
      final response = await patch(router, '/api/config', {'concurrency.max_parallel_turns': 4});

      expect(response.statusCode, 200);
      final json = await readJson(response);
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
      final response = await patch(router, '/api/config', {'port': 8080});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['pendingRestart'], contains('port'));
      expect(json['applied'], isEmpty);

      final restartFile = File(p.join(dataDir, 'restart.pending'));
      expect(restartFile.existsSync(), isTrue);
    });

    test('mixed PATCH: reloadable in applied, restart field in pendingRestart', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final router = createRouterWithNotifier(notifier);

      final response = await patch(router, '/api/config', {
        'concurrency.max_parallel_turns': 4,
        'port': 9090,
      });

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['applied'], contains('concurrency.max_parallel_turns'));
      expect(json['pendingRestart'], contains('port'));
      expect(json['pendingRestart'], isNot(contains('concurrency.max_parallel_turns')));
    });

    test('ConfigNotifier.reload() failure falls back to pendingRestart', () async {
      // Use _ThrowingConfigNotifier to simulate a reload() failure.
      final throwingRouter = _buildRouterWithThrowingNotifier(configPath, dataDir);

      final response = await patch(throwingRouter, '/api/config', {'concurrency.max_parallel_turns': 4});

      expect(response.statusCode, 200);
      final json = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      // Field written to YAML but reload failed → falls back to pendingRestart
      expect(json['applied'], isEmpty);
      expect(json['pendingRestart'], contains('concurrency.max_parallel_turns'));

      final restartFile = File(p.join(dataDir, 'restart.pending'));
      expect(restartFile.existsSync(), isTrue);
    });

    test('PATCH live field fires ConfigChangedEvent and returns in applied', () async {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());
      final bus = EventBus();
      final rc = RuntimeConfig(
        heartbeatEnabled: true,
        gitSyncEnabled: false,
        gitSyncPushEnabled: false,
      );
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
      final response = await patch(router, '/api/config', {'scheduling.heartbeat.enabled': false});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['applied'], contains('scheduling.heartbeat.enabled'));
      expect(json['pendingRestart'], isEmpty);
      expect(captured, isNotNull);
      expect(captured!.changedKeys, contains('scheduling.heartbeat.enabled'));
    });

    test('PATCH with no notifier wired treats reloadable as pendingRestart', () async {
      // createRouter() does not wire a ConfigNotifier
      final router = createRouter();

      final response = await patch(router, '/api/config', {'concurrency.max_parallel_turns': 4});

      expect(response.statusCode, 200);
      final json = await readJson(response);
      expect(json['applied'], isEmpty);
      expect(json['pendingRestart'], contains('concurrency.max_parallel_turns'));
    });
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

class _FakeGowaManager extends GowaManager {
  _FakeGowaManager() : super(executable: '', host: '', port: 0, webhookUrl: '', osName: '');

  @override
  Future<void> start() async {}

  @override
  Future<void> reset() async {}
}
