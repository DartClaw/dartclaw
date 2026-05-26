import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnRunner;
import 'package:dartclaw_server/src/harness_pool.dart' as server_pool;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:sqlite3/sqlite3.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: crash_turn_process.dart <data-dir>');
    exitCode = 64;
    return;
  }

  final dataDir = args.single;
  final db = sqlite3.open('$dataDir/state.db');
  final turnState = TurnStateStore(db);
  final kv = KvService(filePath: '$dataDir/kv.json');
  final messages = MessageService(baseDir: dataDir);
  final sessions = SessionService(baseDir: dataDir);
  final harness = FakeAgentHarness();
  initTemplates('packages/dartclaw_server/lib/src/templates');

  final runner = TurnRunner(
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: dataDir),
    sessions: sessions,
    turnState: turnState,
    kv: kv,
  );

  final builder = DartclawServerBuilder()
    ..sessions = sessions
    ..messages = messages
    ..worker = harness
    ..behavior = BehaviorFileService(workspaceDir: dataDir)
    ..staticDir = 'packages/dartclaw_server/lib/src/static'
    ..kv = kv
    ..pool = server_pool.HarnessPool(runners: [runner], maxConcurrentTasks: 0)
    ..sessionsForTurns = sessions
    ..authEnabled = false;
  final turns = builder.buildTurns();
  final recoveredSessions = await turns.detectAndCleanOrphanedTurns();
  final server = builder.build();
  final httpServer = await shelf_io.serve(server.handler, InternetAddress.loopbackIPv4, 0);

  final ready = File('$dataDir/crash-turn-ready.json');
  ready.writeAsStringSync(jsonEncode({'port': httpServer.port, 'recoveredSessions': recoveredSessions}));

  await ProcessSignal.sigterm.watch().first;
}
