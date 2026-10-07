import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/knowledge/wiki_page_store.dart';
import 'package:dartclaw_runtime/src/mcp/knowledge_write_gate.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/task_tools.dart';
import 'package:dartclaw_runtime/src/mcp/wiki_write_tool.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, WorkflowRunOrigin;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';
import '../mcp/mcp_test_support.dart';
import 'task_executor_test_support.dart';

const _admin = 'admin-a';
const _member = 'member-b';

final class _ContextRecordingWorker extends FakeTaskWorker implements HarnessTurnContextSink {
  HarnessTurnContext? _active;
  final contexts = <HarnessTurnContext>[];

  @override
  HarnessTurnContext? get activeTurnContext => _active;

  @override
  void setTurnContext(HarnessTurnContext? context) {
    _active = context;
    if (context != null) contexts.add(context);
  }
}

TurnProvenance _slackTurn(String sender) => TurnProvenance.channel(
  channelType: ChannelType.slack,
  sessionKey: 'agent:main:group:slack:C1',
  recipientId: 'C1',
  senderId: sender,
);

void main() {
  late _ContextRecordingWorker worker;
  late WorkflowTaskExecutorTestContext ctx;

  setUp(() async {
    worker = _ContextRecordingWorker()..responseText = 'Done.';
    ctx = WorkflowTaskExecutorTestContext(worker);
    await ctx.setUp();
  });

  tearDown(() => ctx.tearDown(workerDispose: worker.dispose));

  Future<void> runQueued() async {
    await ctx.executor.pollOnce();
    await ctx.executor.drain();
    await pumpEventQueue();
  }

  Future<void> startRun(String runId, WorkflowRunOrigin origin) async {
    final now = DateTime.now();
    await ctx.workflowRuns.insert(
      WorkflowRun(
        id: runId,
        definitionName: 'delegated-provenance',
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        definitionJson: const {'name': 'delegated-provenance', 'steps': []},
        variablesJson: const {'PROJECT': '_local'},
        origin: origin,
      ),
    );
  }

  Future<void> queueStep(String id, String runId) async {
    await ctx.tasks.create(
      id: id,
      title: 'Workflow step $id',
      description: 'Run $id.',
      autoStart: true,
      agentExecutionId: 'ae-$id',
      workflowRunId: runId,
      provider: 'claude',
      configJson: const {'needsWorktree': false},
    );
    await ctx.seedWorkflowExecution(id, agentExecutionId: 'ae-$id', workflowRunId: runId);
  }

  Map<String, dynamic> originJson(String? sender) => TaskOrigin(
    channelType: ChannelType.slack.name,
    sessionKey: 'agent:main:group:slack:C1',
    recipientId: 'C1',
    senderId: sender,
  ).toJson();

  group('a delegated turn carries its requester', () {
    test('a task with a chat origin runs as that sender on that channel', () async {
      await ctx.tasks.create(
        id: 'chat-task',
        title: 'Chat task',
        description: 'Started from chat.',
        autoStart: true,
        configJson: {'origin': originJson(_member)},
      );

      await runQueued();

      expect(worker.contexts.map((context) => context.provenance), [_slackTurn(_member)]);
    });

    test('a task with no origin keeps a turn with no provenance', () async {
      await ctx.tasks.create(id: 'plain-task', title: 'Plain', description: 'No origin.', autoStart: true);

      await runQueued();

      expect(worker.contexts.map((context) => context.provenance), [null]);
    });

    test('a workflow step runs as the sender of the chat run it belongs to, thread included', () async {
      await startRun(
        'wf-chat',
        const WorkflowRunOrigin(
          surface: 'slack',
          channelType: 'slack',
          recipientId: 'C1',
          threadId: '1700000000.000100',
          sessionKey: 'agent:main:group:slack:C1',
          senderId: _member,
        ),
      );
      await queueStep('chat-step', 'wf-chat');

      await runQueued();

      expect(worker.contexts.single.provenance, isNotNull);
      final provenance = worker.contexts.single.provenance!;
      expect(
        (provenance.channelType, provenance.senderId, provenance.recipientId, provenance.threadId),
        ('slack', _member, 'C1', '1700000000.000100'),
      );
    });

    test('a workflow step of a run started outside chat stays non-channel', () async {
      for (final surface in ['web', 'api', 'cli', 'github', 'cron', 'unknown']) {
        worker.contexts.clear();
        await startRun('wf-$surface', WorkflowRunOrigin(surface: surface));
        await queueStep('step-$surface', 'wf-$surface');

        await runQueued();

        expect(worker.contexts.map((context) => context.provenance), [null], reason: surface);
      }
    });
  });

  group('the shared-knowledge write gate over a delegated turn', () {
    late Directory workspace;
    late RecordingGuardAuditLogger audit;
    late McpProtocolHandler base;

    setUp(() {
      workspace = Directory.systemTemp.createTempSync('delegated_write_gate_');
      audit = RecordingGuardAuditLogger();
      final gate = KnowledgeWriteGate(
        isAdmin: const GovernanceConfig(adminSenders: [_admin]).isAdmin,
        auditLogger: audit,
        refuseFirst: (_) async => null,
      );
      base = McpProtocolHandler()
        ..registerTool(TaskCreateTool(tasks: ctx.tasks))
        ..registerTool(
          WikiWriteTool(
            wiki: WikiPageStore(workspaceDir: workspace.path),
            contextualWriteGuard: gate.guardFor('wiki_write'),
          ),
        );
    });

    tearDown(() => workspace.deleteSync(recursive: true));

    Future<Map<String, dynamic>> wikiWriteDuring(TurnProvenance? turn, String slug) async => toolResult(
      await callTool(
        base.forHarness(() => turn),
        'wiki_write',
        arguments: {
          'slug': slug,
          'title': 'Delegated',
          'body': 'Written by a task.',
          'sources': ['delegated-test'],
        },
      ),
    );

    Future<TurnProvenance?> delegatedTurnOf(String requester) async {
      worker.contexts.clear();
      final created = resultPayload(
        toolResult(
          await callTool(
            base.forHarness(() => _slackTurn(requester)),
            'task_create',
            arguments: {'title': 'Write wiki', 'description': 'Record this.', 'auto_start': true},
          ),
        ),
      );
      expect(created['status'], 'queued');
      await runQueued();
      return worker.contexts.single.provenance;
    }

    File page(String slug) => File(p.join(workspace.path, 'wiki', '$slug.md'));

    test('a task a non-admin asked for cannot write the wiki, and the refusal is audited', () async {
      final turn = await delegatedTurnOf(_member);

      final refusal = await wikiWriteDuring(turn, 'by-member-task');

      expect(refusal['isError'], isTrue);
      expect(resultText(refusal), contains('admin_senders'));
      expect(page('by-member-task').existsSync(), isFalse);
      expect(audit.entries.map((entry) => (entry.guard, entry.tool, entry.channel, entry.peerId, entry.decision)), [
        ('KnowledgeWriteGate', 'wiki_write', 'slack', _member, 'deny'),
      ]);
    });

    test('a task an admin asked for can write the wiki, and the write is audited', () async {
      final turn = await delegatedTurnOf(_admin);

      final written = await wikiWriteDuring(turn, 'by-admin-task');

      expect(written['isError'], isNot(true));
      expect(page('by-admin-task').existsSync(), isTrue);
      expect(audit.entries.map((entry) => (entry.peerId, entry.decision)), [(_admin, 'allow')]);
    });

    test('a workflow step of a non-admin chat run cannot write the wiki', () async {
      await startRun(
        'wf-gated',
        const WorkflowRunOrigin(
          surface: 'slack',
          channelType: 'slack',
          recipientId: 'C1',
          sessionKey: 'agent:main:group:slack:C1',
          senderId: _member,
        ),
      );
      await queueStep('gated-step', 'wf-gated');
      await runQueued();

      final refusal = await wikiWriteDuring(worker.contexts.single.provenance, 'by-member-step');

      expect(refusal['isError'], isTrue);
      expect(page('by-member-step').existsSync(), isFalse);
      expect(audit.entries.map((entry) => (entry.peerId, entry.decision)), [(_member, 'deny')]);
    });

    test('a workflow step of an admin chat run can write the wiki', () async {
      await startRun(
        'wf-admin',
        const WorkflowRunOrigin(
          surface: 'slack',
          channelType: 'slack',
          recipientId: 'C1',
          sessionKey: 'agent:main:group:slack:C1',
          senderId: _admin,
        ),
      );
      await queueStep('admin-step', 'wf-admin');
      await runQueued();

      final written = await wikiWriteDuring(worker.contexts.single.provenance, 'by-admin-step');

      expect(written['isError'], isNot(true));
      expect(page('by-admin-step').existsSync(), isTrue);
    });

    test('a task created outside a chat turn records no origin and stays ungated like a web turn', () async {
      await callTool(
        base.forHarness(() => const TurnProvenance.web(sessionKey: 'agent:main:web:abc')),
        'task_create',
        arguments: {'title': 'Web task', 'description': 'From the web.'},
      );

      final task = (await ctx.tasks.list()).single;

      expect(TaskOrigin.fromConfigJson(task.configJson), isNull);
      expect(jsonEncode(task.configJson), isNot(contains('origin')));
    });
  });
}
