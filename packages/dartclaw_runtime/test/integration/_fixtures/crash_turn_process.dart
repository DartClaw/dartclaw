import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:sqlite3/sqlite3.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:dartclaw_runtime/src/server.dart' show ServerCoreDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';

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
  final packageUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
  final packageRoot = p.normalize(p.join(p.dirname(packageUri!.toFilePath()), '..'));
  initTemplates(p.join(packageRoot, 'lib', 'src', 'templates'));

  final runner = TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: dataDir),
    sessions: sessions,
    turnState: turnState,
    kv: kv,
  );

  final executions = ExecutionCoordinator(
    providerCapacities: const {},
    primary: runner,
    admitExecution: (request) => runner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
    releaseAdmission: runner.releaseAdmission,
    createWorker: (_) => throw StateError('Worker execution is disabled'),
  );
  final turns = composeServerTurns(
    sessions: sessions,
    messages: messages,
    worker: harness,
    behavior: BehaviorFileService(workspaceDir: dataDir),
    kv: kv,
    executions: executions,
    sessionsForTurns: sessions,
  );
  final recoveredSessions = await turns.detectAndCleanOrphanedTurns();
  final server = composeServer(
    core: ServerCoreDeps(
      sessions: sessions,
      messages: messages,
      worker: harness,
      staticDir: p.join(packageRoot, 'lib', 'src', 'static'),
      kvService: kv,
      authEnabled: false,
    ),
    turn: ServerTurnDeps(turns: turns, executions: executions),
  );
  final httpServer = await shelf_io.serve(server.handler, InternetAddress.loopbackIPv4, 0);

  final ready = File('$dataDir/crash-turn-ready.json');
  ready.writeAsStringSync(jsonEncode({'port': httpServer.port, 'recoveredSessions': recoveredSessions}));

  await ProcessSignal.sigterm.watch().first;
}
