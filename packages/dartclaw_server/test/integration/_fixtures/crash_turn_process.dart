import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnRunner;
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
  // The test captures this process's stderr for its timeout diagnostics, so
  // server-side warnings (e.g. the exception behind a generic 500) must land there.
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((record) => stderr.writeln('[${record.loggerName}] ${record.message}'));
  final db = sqlite3.open('$dataDir/state.db');
  final turnState = TurnStateStore(db);
  final kv = KvService(filePath: '$dataDir/kv.json');
  final messages = MessageService(baseDir: dataDir);
  final sessions = SessionService(baseDir: dataDir);
  final harness = FakeAgentHarness();
  // Resolved from the package location, not the cwd: this process is spawned
  // by a test whose own cwd differs between root-level and package-level
  // `dart test` invocations.
  final packageUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  final packageRoot = p.normalize(p.join(p.dirname(packageUri!.toFilePath()), '..'));
  initTemplates(p.join(packageRoot, 'lib', 'src', 'templates'));

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
    ..staticDir = p.join(packageRoot, 'lib', 'src', 'static')
    ..kv = kv
    ..executions = ExecutionCoordinator(
      providerCapacities: const {},
      primary: runner,
      admitExecution: (request) => runner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: runner.releaseAdmission,
      createWorker: (_) => throw StateError('Worker execution is disabled'),
    )
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
