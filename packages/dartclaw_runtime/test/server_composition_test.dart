import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/server.dart' show ServerCoreDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager;
import 'package:test/test.dart';

import 'guard_audit_test_support.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_runtime_builder_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeAgentHarness();
  });

  tearDown(() async {
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TurnManager turnsWith({
    GuardChain? guardChain,
    TaskToolFilterGuard? filter,
    ExecutionPolicy executionPolicy = const ExecutionPolicy.host(),
  }) => composeServerTurns(
    sessions: sessions,
    messages: messages,
    worker: worker,
    behavior: BehaviorFileService(workspaceDir: tempDir.path),
    guardChain: guardChain,
    taskToolFilterGuard: filter,
    executionPolicy: executionPolicy,
  );

  DartclawServer serverWith({ResultTrimmer? resultTrimmer, GuardChain? guardChain, GuardAuditLogger? auditLogger}) =>
      composeServer(
        core: ServerCoreDeps(
          sessions: sessions,
          messages: messages,
          worker: worker,
          staticDir: tempDir.path,
          guardChain: guardChain,
          auditLogger: auditLogger,
          resultTrimmer: resultTrimmer,
        ),
        turn: ServerTurnDeps(turns: turnsWith(guardChain: guardChain)),
      );

  group('guard enforcement requires an audit sink', () {
    test('a guard chain with no audit logger is refused at composition', () {
      // The two deps are independent nullables, so nothing downstream reports
      // the omission: the dispatch seam's audit is a no-op on a null sink.
      expect(
        () => serverWith(guardChain: GuardChain(guards: [])),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'auditLogger')
              .having((e) => e.message.toString(), 'message', contains('requires an audit sink')),
        ),
      );
    });

    test('guarding nothing and auditing nothing stays a legal composition', () {
      expect(serverWith(), isA<DartclawServer>());
    });
  });

  group('composeServerTurns tool policy wiring', () {
    test('a host-layered filter enforces the turn policy on the chain the harness evaluates', () async {
      // A host composes the harness chain the way serve wiring does: the base
      // security chain plus this runner's own filter.
      final base = GuardChain(guards: []);
      final filter = TaskToolFilterGuard();
      final harnessChain = GuardChain.layered(base: base, guards: [filter]);

      final turns = turnsWith(guardChain: base, filter: filter);
      final session = await sessions.createSession();
      final turnId = await turns.startTurn(
        session.id,
        [
          {'role': 'user', 'content': 'extract facts'},
        ],
        allowedTools: const ['__knowledge_inbox_no_tools__'],
        readOnly: true,
      );
      await worker.turnInvoked;

      final midTurn = await harnessChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
      expect(midTurn.isBlock, isTrue);
      expect(midTurn.message, contains('__knowledge_inbox_no_tools__'));

      // The policy is session-scoped, not chain-wide.
      final otherSession = await harnessChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: 'other');
      expect(otherSession.isBlock, isFalse);

      worker.completeSuccess();
      await turns.waitForOutcome(session.id, turnId);

      final postTurn = await harnessChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
      expect(postTurn.isBlock, isFalse);
    });

    test('a turn with tool policy runs when the host supplies no filter', () async {
      // Covers the optional taskToolFilterGuard: a turn carrying allowedTools
      // and readOnly must still complete when no filter was supplied. That the
      // composer does not fabricate one cannot be asserted from outside — an
      // invented filter sits outside the harness's chain and is inert by
      // construction, which is precisely why the old behaviour was a silent bug.
      // The enforcing case is the test above.
      final base = GuardChain(guards: []);
      final turns = turnsWith(guardChain: base);

      final session = await sessions.createSession();
      final turnId = await turns.startTurn(
        session.id,
        [
          {'role': 'user', 'content': 'extract facts'},
        ],
        allowedTools: const ['__knowledge_inbox_no_tools__'],
        readOnly: true,
      );
      await worker.turnInvoked;

      worker.completeSuccess();
      final outcome = await turns.waitForOutcome(session.id, turnId);
      expect(outcome.status, TurnStatus.completed);
    });
  });

  group('composeServerTurns execution placement', () {
    test('a host composing a container-backed worker reports its real placement', () {
      // The composer receives an already-constructed worker and cannot infer
      // where it runs, so an SDK host that containerized one must be able to
      // say so — the policy is the runner's reported placement and its
      // never-cache-container reuse identity.
      final turns = turnsWith(executionPolicy: const ExecutionPolicy.container('restricted'));
      addTearDown(turns.executions.dispose);

      expect(turns.executions.primary!.executionPolicy, const ExecutionPolicy.container('restricted'));
    });

    test('an unset policy stays host, what an SDK host composes by default', () {
      final turns = turnsWith();
      addTearDown(turns.executions.dispose);

      expect(turns.executions.primary!.executionPolicy, const ExecutionPolicy.host());
    });
  });

  group('composeServer MCP dispatch guard wiring', () {
    test('a composed server refuses and audits a guard-blocked tool call', () async {
      final audit = RecordingGuardAuditLogger();
      final tool = _BulkTool('never returned');
      final server = serverWith(
        guardChain: GuardChain(guards: [_BlockingGuard()]),
        auditLogger: audit,
      )..registerTool(tool);
      addTearDown(server.turns.executions.dispose);

      final response = await server.mcpHandler.handleRequest(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'bulk'},
        }),
      );
      final decoded = jsonDecode(response!) as Map<String, dynamic>;
      final result = decoded['result'] as Map<String, dynamic>;

      expect(decoded.containsKey('error'), isFalse);
      expect(result['isError'], isTrue);
      expect((result['content'] as List)[0]['text'], 'no tools here');
      expect(audit.entries.single.decision, 'deny');
      expect(audit.entries.single.tool, 'bulk');
      expect(audit.entries.single.reason, 'access=read no tools here');
    });
  });

  group('composeServer result-trimmer wiring', () {
    Future<String> callBulkTool(DartclawServer server) async {
      final response = await server.mcpHandler.handleRequest(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'bulk'},
        }),
      );
      final result = (jsonDecode(response!) as Map<String, dynamic>)['result'] as Map<String, dynamic>;
      return (result['content'] as List)[0]['text'] as String;
    }

    test('the configured trimmer reaches tools/call dispatch', () async {
      // 20 KB is under the fallback's 50 KB default, so this can only pass if
      // the composer-supplied 8 KB instance is the one dispatch consults.
      final payload = 'x' * (20 * 1024);
      final server = serverWith(resultTrimmer: ResultTrimmer(maxBytes: 8 * 1024))..registerTool(_BulkTool(payload));
      addTearDown(server.turns.executions.dispose);

      final text = await callBulkTool(server);

      expect(text, contains('...[trimmed '));
      expect(utf8.encode(text).length, lessThanOrEqualTo(8 * 1024));
    });

    test('an unset trimmer still caps at the documented 50KB default', () async {
      final payload = 'x' * (60 * 1024);
      final server = serverWith()..registerTool(_BulkTool(payload));
      addTearDown(server.turns.executions.dispose);

      final text = await callBulkTool(server);

      expect(text, contains('...[trimmed '));
      expect(utf8.encode(text).length, lessThanOrEqualTo(50 * 1024));
    });
  });
}

/// Returns a fixed payload, so a test can put a chosen byte size through the
/// server's own `tools/call` dispatch.
class _BulkTool implements McpTool {
  new(this.content);

  final String content;

  @override
  String get name => 'bulk';

  @override
  String get description => 'Returns a fixed payload';

  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text(content);
}

class _BlockingGuard extends Guard {
  @override
  String get name => 'BlockingGuard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async => GuardVerdict.block('no tools here');
}
