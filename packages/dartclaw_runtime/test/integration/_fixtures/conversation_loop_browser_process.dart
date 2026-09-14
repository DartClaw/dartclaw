import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/server.dart' show ServerCoreDeps, ServerObservabilityDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: conversation_loop_browser_process.dart <data-dir> <port>');
    exitCode = 64;
    return;
  }
  final dataDirectory = arguments.first;
  final port = int.parse(arguments.last);
  final turnState = openTurnStateStore(p.join(dataDirectory, 'turn_state.json'));
  final kv = KvService(filePath: p.join(dataDirectory, 'kv.json'));
  final messages = MessageService(baseDir: dataDirectory);
  final eventBus = EventBus();
  final sessions = SessionService(baseDir: dataDirectory, eventBus: eventBus);
  final channelSession = await _seedExternalSession(
    sessions,
    messages,
    type: SessionType.channel,
    channelKey: 'signal:fixture-owner',
  );
  final cronSession = await _seedExternalSession(sessions, messages, type: SessionType.cron, provider: 'claude');
  final harness = FakeAgentHarness();
  final packageUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
  final packageRoot = p.normalize(p.join(p.dirname(packageUri!.toFilePath()), '..'));
  initTemplates(p.join(packageRoot, 'lib', 'src', 'templates'));

  final runner = TurnRunner(
    turnLimits: const TurnLimitsConfig.defaults(),
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: dataDirectory),
    sessions: sessions,
    turnState: turnState,
    kv: kv,
    eventBus: eventBus,
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
    behavior: BehaviorFileService(workspaceDir: dataDirectory),
    kv: kv,
    executions: executions,
    sessionsForTurns: sessions,
  );
  final recoveredSessions = await turns.detectAndCleanOrphanedTurns();
  await turns.reserveTurn(
    channelSession.id,
    isHumanInput: true,
    promptScope: PromptScope.primary,
    origin: (channel: SessionType.channel.name, contact: null, group: false),
  );
  await turns.reserveTurn(
    cronSession.id,
    promptScope: PromptScope.primary,
    origin: (channel: SessionType.cron.name, contact: null, group: false),
  );
  final broadcast = SseBroadcast();
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
    observability: ServerObservabilityDeps(sseBroadcast: broadcast, eventBus: eventBus),
  );
  final revokedViewers = File(p.join(dataDirectory, 'revoked-viewers.txt'));
  final handler = _revocationGuard(server.handler, revokedViewers);
  final httpServer = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
  File(p.join(dataDirectory, 'conversation-browser-ready.json')).writeAsStringSync(
    jsonEncode({
      'port': httpServer.port,
      'recoveredSessions': recoveredSessions,
      'channelSessionId': channelSession.id,
      'cronSessionId': cronSession.id,
    }),
    flush: true,
  );
  await ProcessSignal.sigterm.watch().first;
  await httpServer.close(force: true);
  await turnState.dispose();
  await kv.dispose();
  await eventBus.dispose();
}

Future<Session> _seedExternalSession(
  SessionService sessions,
  MessageService messages, {
  required SessionType type,
  String? channelKey,
  String? provider,
}) async {
  final existing = (await sessions.listSessions(type: type)).firstOrNull;
  if (existing != null) return existing;
  final session = await sessions.createSession(type: type, channelKey: channelKey, provider: provider);
  await messages.insertMessage(sessionId: session.id, role: 'user', content: '${type.name} fixture activity');
  return session;
}

Handler _revocationGuard(Handler inner, File revokedViewers) {
  return (request) {
    final viewer = request.headers['x-conversation-viewer'];
    if (viewer != null && revokedViewers.existsSync()) {
      final revoked = revokedViewers.readAsLinesSync().map((line) => line.trim()).toSet();
      if (revoked.contains(viewer)) return Response.forbidden('Viewer authorization revoked');
    }
    return inner(request);
  };
}
