import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:path/path.dart' as p;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

/// `PATCH /api/config` against the entry shapes the field registry declares.
///
/// Until 0.25 `ConfigEntryShape` / `EntryFieldMeta` had no production consumer,
/// so an object-valued section was checked only as `value is Map` / `value is
/// List` and every key inside one entry reached the runtime uninspected.
void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_entry_shape_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    File(configPath).writeAsStringSync('port: 3000\nhost: localhost\n');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Router createRouter() {
    const cfg = DartclawConfig.defaults();
    return configApiRoutes(
      config: cfg,
      writer: ConfigWriter(configPath: configPath),
      validator: const ConfigValidator(),
      runtimeConfig: RuntimeConfig(
        heartbeatEnabled: cfg.scheduling.heartbeatEnabled,
        gitSyncEnabled: cfg.workspace.gitSyncEnabled,
        gitSyncPushEnabled: cfg.workspace.gitSyncPushEnabled,
      ),
      dataDir: dataDir,
    );
  }

  ApiRouteTestClient adminApi(Router router) =>
      ApiRouteTestClient((request) => router.call(withAdminAuthContext(request)));

  // The registry declares what one `agent.agents` entry may contain; until
  // 0.25 nothing consumed that declaration, so a per-entry key deciding
  // placement or posture reached the runtime through a map the API never
  // inspected and failed — if at all — at the next boot.
  test('a per-entry posture key outside its declared values returns 400 naming the entry', () async {
    final router = createRouter();
    final json = await adminApi(router).expectJsonObject(
      'PATCH',
      '/api/config',
      json: {
        'agent.agents': {
          'researcher': {'prompt': 'research things', 'execution': 'bare-metal'},
        },
      },
      status: 400,
    );

    final errors = json['errors'] as List;
    expect((errors.first as Map<String, dynamic>)['field'], 'agent.agents.researcher.execution');
    expect((errors.first as Map<String, dynamic>)['message'], contains('host'));
  });

  test('an out-of-range per-entry number is refused at write time', () async {
    final router = createRouter();
    final json = await adminApi(router).expectJsonObject(
      'PATCH',
      '/api/config',
      json: {
        'agent.agents': {
          'researcher': {'prompt': 'research things', 'max_response_bytes': -1},
        },
      },
      status: 400,
    );

    expect(
      ((json['errors'] as List).first as Map<String, dynamic>)['field'],
      'agent.agents.researcher.max_response_bytes',
    );
  });

  test('an undeclared key inside an entry is still accepted', () async {
    // Several entries are open on purpose — `ProviderEntry.options` absorbs
    // unnamed `providers.<id>` keys and `dartclaw init` writes some itself —
    // and no entry shape declares whether it is closed. Refusing here would
    // refuse a config DartClaw wrote.
    final router = createRouter();
    await adminApi(router).expectJsonObject(
      'PATCH',
      '/api/config',
      json: {
        'agent.agents': {
          'researcher': {'prompt': 'research things', 'not_a_declared_key': 'x'},
        },
      },
      status: 200,
    );
  });
}
