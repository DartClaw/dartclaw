import 'dart:io';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late DartclawServer server;
  late Map<String, List<int>> previousAssets;
  late Map<String, String> previousMimeTypes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_static_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeAgentHarness();
    previousAssets = Map<String, List<int>>.from(embeddedStaticAssets);
    previousMimeTypes = Map<String, String>.from(embeddedStaticMimeTypes);

    embeddedStaticAssets
      ..clear()
      ..['app.js'] = utf8.encode('console.log("embedded");');
    embeddedStaticMimeTypes
      ..clear()
      ..['app.js'] = 'application/javascript';

    server =
        (DartclawServerBuilder()
              ..sessions = sessions
              ..messages = messages
              ..worker = worker
              ..staticDir = tempDir.path
              ..behavior = BehaviorFileService(workspaceDir: tempDir.path))
            .build();
  });

  tearDown(() async {
    embeddedStaticAssets
      ..clear()
      ..addAll(previousAssets);
    embeddedStaticMimeTypes
      ..clear()
      ..addAll(previousMimeTypes);
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('GET /static/app.js serves embedded bytes with the embedded MIME type', () async {
    final response = await server.handler(Request('GET', Uri.parse('http://localhost/static/app.js')));

    expect(response.statusCode, equals(200));
    expect(response.headers['content-type'], startsWith('application/javascript'));
    expect(response.headers['cache-control'], equals('public, max-age=86400'));
    expect(await response.readAsString(), contains('embedded'));
  });
}
