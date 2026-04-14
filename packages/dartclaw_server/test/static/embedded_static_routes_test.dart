import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
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

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_static_test_');
    final staticDir = Directory(p.join(tempDir.path, 'static'))..createSync(recursive: true);
    File(p.join(staticDir.path, 'app.js')).writeAsStringSync('console.log("filesystem");');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeAgentHarness();

    server =
        (DartclawServerBuilder()
              ..sessions = sessions
              ..messages = messages
              ..worker = worker
              ..staticDir = staticDir.path
              ..behavior = BehaviorFileService(workspaceDir: tempDir.path))
            .build();
  });

  tearDown(() async {
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('GET /static/app.js serves filesystem bytes with the cache header', () async {
    final response = await server.handler(Request('GET', Uri.parse('http://localhost/static/app.js')));

    expect(response.statusCode, equals(200));
    expect(response.headers['content-type'], startsWith('text/javascript'));
    expect(response.headers['cache-control'], equals('public, max-age=86400'));
    expect(await response.readAsString(), contains('filesystem'));
  });
}
