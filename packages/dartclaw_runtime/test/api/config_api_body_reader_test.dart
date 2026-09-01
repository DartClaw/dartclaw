import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/auth/request_auth_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'api_test_helpers.dart';

/// `PATCH /api/config` reads through the shared capped reader in
/// `api_helpers.dart`; these pin the rejection contract it must keep answering.
void main() {
  late Directory tempDir;
  late ApiRouteTestClient admin;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_api_body_test_');
    final configPath = p.join(tempDir.path, 'dartclaw.yaml');
    final dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    File(configPath).writeAsStringSync('port: 3000\n');

    final router = configApiRoutes(
      config: const DartclawConfig.defaults(),
      writer: ConfigWriter(configPath: configPath),
      validator: const ConfigValidator(),
      runtimeConfig: RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true),
      dataDir: dataDir,
      eventBus: EventBus(),
    );
    admin = ApiRouteTestClient((request) => router.call(withAdminAuthContext(request)));
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  for (final body in const ['', '{not json', '[]']) {
    test('rejects body ${jsonEncode(body)} with the published invalid-JSON message', () async {
      final json = await admin.expectJsonObject(
        'PATCH',
        '/api/config',
        body: body,
        headers: const {'content-type': 'application/json'},
        status: 400,
      );

      expect(json, containsPair('error', containsPair('message', 'Request body must be valid JSON')));
    });
  }

  test('refuses a body above the 128 KB config cap', () async {
    final json = await admin.expectJsonObject(
      'PATCH',
      '/api/config',
      body: '{"port":${'9' * (128 * 1024)}}',
      headers: const {'content-type': 'application/json'},
      status: 413,
    );

    expect(json, containsPair('error', containsPair('code', 'REQUEST_TOO_LARGE')));
  });
}
