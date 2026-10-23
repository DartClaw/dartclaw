import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/workflow_tools.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGuard, InMemoryTaskRepository;
import 'package:dartclaw_workflow/testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowDefinitionSource, WorkflowRun, WorkflowRunOrigin, WorkflowStep, WorkflowVariable;
import 'package:test/test.dart';

import 'package:dartclaw_runtime/src/task/workflow_start_precondition_exception.dart';

import '../api/workflow_test_support.dart';
import '../guard_audit_test_support.dart';
import 'mcp_test_support.dart';

/// One required variable and one optional variable carrying a default — the
/// two halves of the contract `workflow_list` has to publish.
final _nightlyReview = WorkflowDefinition(
  name: 'nightly-review',
  description: 'Review whatever the scope names',
  variables: const {
    'SCOPE': WorkflowVariable(required: true, description: 'What to review'),
    'DEPTH': WorkflowVariable(required: false, description: 'How deep to look', defaultValue: 'shallow'),
  },
  steps: const [
    WorkflowStep(id: 'review', name: 'Review', prompts: ['Review it']),
  ],
);

void main() {
  late Directory tempDir;
  late TaskService tasks;
  late FakeWorkflowService workflows;
  late RecordingGuardAuditLogger audit;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_tools_');
    final eventBus = EventBus();
    tasks = TaskService(InMemoryTaskRepository(), eventBus: eventBus);
    workflows = FakeWorkflowService(taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
    // The required-variable rule lives in WorkflowService.start, so the fake has
    // to keep it for the tool's refusal path to exist at all.
    workflows.validateRequiredVars = true;
    workflows.startResult = WorkflowRun(
      id: 'wf-run-2f7c',
      definitionName: 'nightly-review',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
    );
    audit = RecordingGuardAuditLogger();
  });

  tearDown(() async {
    await workflows.dispose();
    await tasks.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Registers both real tools on the real dispatch seam.
  ///
  /// Guard evaluation and audit come from [McpProtocolHandler]; neither tool
  /// participates, which is what the negative control proves.
  McpProtocolHandler handlerWith({GuardChain? chain, GuardAuditLogger? sink, WorkflowDefinitionSource? definitions}) {
    final source = definitions ?? InMemoryDefinitionSource([_nightlyReview]);
    return McpProtocolHandler(guardChain: chain, auditLogger: sink)
      ..registerTool(WorkflowRunTool(definitions: source, workflows: workflows))
      ..registerTool(WorkflowListTool(definitions: source));
  }

  McpProtocolHandler passingHandler({WorkflowDefinitionSource? definitions}) => handlerWith(
    chain: GuardChain(guards: [FakeGuard.pass()]),
    sink: audit,
    definitions: definitions,
  );

  group('S01 workflow_run starts a named workflow with its parameters', () {
    test('the payload names the run and its location, and the run is in the run store', () async {
      final payload = resultPayload(
        toolResult(
          await callTool(
            passingHandler(),
            'workflow_run',
            arguments: {
              'definition': 'nightly-review',
              'variables': {'SCOPE': 'inbox'},
            },
          ),
        ),
      );

      expect(payload['run_id'], 'wf-run-2f7c');
      expect(payload['definition'], 'nightly-review');
      expect(payload['status'], 'running');
      // The location is what makes the run openable in the web UI without a
      // second lookup, so a bare ID would defeat the surface.
      expect(payload['location'], '/workflows/wf-run-2f7c');

      final stored = await workflows.list(definitionName: 'nightly-review');
      expect(stored, hasLength(1));
      expect(stored.single.id, 'wf-run-2f7c');
      expect(stored.single.variablesJson, {'SCOPE': 'inbox'});
      expect(workflows.startCalls, 1);

      expect(audit.entries.map((entry) => (entry.tool, entry.decision, entry.verdict)), [
        ('workflow_run', 'allow', 'pass'),
      ]);
    });
  });

  group('run origin', () {
    final chatTurn = TurnProvenance.channel(
      channelType: ChannelType.googlechat,
      recipientId: 'spaces/AAA',
      threadId: 'spaces/AAA/threads/T1',
      sessionKey: 'agent:main:group:googlechat:spaces%2FAAA',
      senderId: 'users/42',
    );
    const runArguments = {
      'definition': 'nightly-review',
      'variables': {'SCOPE': 'inbox'},
    };

    McpProtocolHandler hostHarness(TurnProvenance? Function() activeTurn) => passingHandler().forHarness(activeTurn);

    test('a host harness turn from a chat thread records that thread, sender and session', () async {
      toolResult(await callTool(hostHarness(() => chatTurn), 'workflow_run', arguments: runArguments));

      expect(
        workflows.lastOrigin,
        const WorkflowRunOrigin(
          surface: 'googlechat',
          channelType: 'googlechat',
          recipientId: 'spaces/AAA',
          threadId: 'spaces/AAA/threads/T1',
          sessionKey: 'agent:main:group:googlechat:spaces%2FAAA',
          senderId: 'users/42',
        ),
      );
    });

    test('a web-chat turn records web and its session key and no channel field', () async {
      const webTurn = TurnProvenance.web(sessionKey: 'agent:main:web:abc');

      toolResult(await callTool(hostHarness(() => webTurn), 'workflow_run', arguments: runArguments));

      expect(workflows.lastOrigin, const WorkflowRunOrigin(surface: 'web', sessionKey: 'agent:main:web:abc'));
    });

    test('a scheduled prompt turn records cron and nothing else', () async {
      toolResult(
        await callTool(hostHarness(() => const TurnProvenance.cron()), 'workflow_run', arguments: runArguments),
      );

      expect(workflows.lastOrigin, const WorkflowRunOrigin(surface: 'cron'));
    });

    test('a caller that is running no turn records api, whatever the lane', () async {
      toolResult(await callTool(passingHandler(), 'workflow_run', arguments: runArguments));
      expect(workflows.lastOrigin, const WorkflowRunOrigin(surface: 'api'));

      workflows.lastOrigin = null;
      toolResult(await callTool(hostHarness(() => null), 'workflow_run', arguments: runArguments));
      expect(workflows.lastOrigin, const WorkflowRunOrigin(surface: 'api'));

      workflows.lastOrigin = null;
      await WorkflowRunTool(
        definitions: InMemoryDefinitionSource([_nightlyReview]),
        workflows: workflows,
      ).call(runArguments);
      expect(workflows.lastOrigin, const WorkflowRunOrigin(surface: 'api'));
    });

    test('origin-like arguments are refused as unknown arguments and start nothing', () async {
      for (final field in ['surface', 'origin', 'channelType', 'recipientId', 'threadId', 'sessionKey', 'senderId']) {
        final response = await callTool(
          hostHarness(() => chatTurn),
          'workflow_run',
          arguments: {...runArguments, field: 'forged'},
        );

        expect((response['error'] as Map)['message'], contains('unknown argument "$field"'), reason: field);
      }
      expect(workflows.startCalls, 0);
    });

    test('a scoped caller the transport gave no identity is refused rather than given the steward defaults', () async {
      final handler = passingHandler().scopedTo(AllowAllCallerPolicy(), activeTurn: () => chatTurn);

      final result = toolResult(await callTool(handler, 'workflow_run', arguments: runArguments));

      expect(result['isError'], isTrue);
      expect(resultText(result), 'Tool requires authenticated caller context');
      expect(workflows.startCalls, 0);
    });

    test('a container authority resolves each turn at call time and carries none after the turn ends', () async {
      TurnProvenance? active;
      final handler = passingHandler().scopedTo(
        AllowAllCallerPolicy(),
        callerIdentity: const McpCallerIdentity(authorityId: 'authority-1', agentId: 'ana'),
        activeTurn: () => active,
      );
      final bob = TurnProvenance.channel(
        channelType: ChannelType.googlechat,
        recipientId: 'spaces/AAA',
        threadId: 'spaces/AAA/threads/T2',
        sessionKey: 'shared-session',
        senderId: 'users/bob',
      );
      final alice = TurnProvenance.channel(
        channelType: ChannelType.googlechat,
        recipientId: 'spaces/AAA',
        threadId: 'spaces/AAA/threads/T1',
        sessionKey: 'shared-session',
        senderId: 'users/alice',
      );

      final origins = <WorkflowRunOrigin?>[];
      for (final turn in [alice, bob, null]) {
        active = turn;
        toolResult(await callTool(handler, 'workflow_run', arguments: runArguments));
        origins.add(workflows.lastOrigin);
      }

      expect(origins.map((origin) => origin?.senderId), ['users/alice', 'users/bob', null]);
      expect(origins.map((origin) => origin?.threadId), ['spaces/AAA/threads/T1', 'spaces/AAA/threads/T2', null]);
      expect(origins.last?.surface, 'api');
    });
  });

  group('S02 a missing required variable and an unknown definition are tool errors that start nothing', () {
    test('the missing variable is named, as invalid_variables, and no run is started', () async {
      final result = toolResult(
        await callTool(passingHandler(), 'workflow_run', arguments: {'definition': 'nightly-review'}),
      );

      expect(result['isError'], isTrue);
      expect(resultPayload(result)['reason'], 'invalid_variables');
      expect(resultPayload(result)['message'], 'Missing required variable(s): SCOPE');
      expect(workflows.activeRuns, isEmpty);
      expect(workflows.startCalls, 0);
    });

    test('an unregistered definition is named, as unknown_definition, and no run is started', () async {
      final result = toolResult(
        await callTool(
          passingHandler(),
          'workflow_run',
          arguments: {
            'definition': 'ghost-review',
            'variables': {'SCOPE': 'inbox'},
          },
        ),
      );

      expect(result['isError'], isTrue);
      expect(resultPayload(result)['reason'], 'unknown_definition');
      expect(resultPayload(result)['message'], 'No workflow definition named ghost-review');
      expect(resultPayload(result)['definition'], 'ghost-review');
      expect(workflows.activeRuns, isEmpty);
      expect(workflows.startCalls, 0);
    });
  });

  group('a start precondition the service refuses is a tool error too', () {
    test('WorkflowStartPreconditionException is reported as precondition_failed with no run started', () async {
      workflows.startError = const WorkflowStartPreconditionException('workspace has uncommitted changes');

      final result = toolResult(
        await callTool(
          passingHandler(),
          'workflow_run',
          arguments: {
            'definition': 'nightly-review',
            'variables': {'SCOPE': 'inbox'},
          },
        ),
      );

      expect(result['isError'], isTrue);
      expect(resultPayload(result)['reason'], 'precondition_failed');
      expect(resultPayload(result)['message'], 'workspace has uncommitted changes');
      expect(workflows.activeRuns, isEmpty);
    });
  });

  group('S03 workflow_list carries the variable contract', () {
    test('both variables are listed with their required flag, and only the optional one carries a default', () async {
      final payload = resultPayload(toolResult(await callTool(passingHandler(), 'workflow_list')));
      final listed = (payload['workflows'] as List).cast<Map<String, dynamic>>();

      expect(listed, hasLength(1));
      expect(listed.single['name'], 'nightly-review');
      expect(listed.single['description'], 'Review whatever the scope names');
      // Exact maps, because the absence of a `default` key on a required
      // variable is the half of the contract a `contains` check cannot see.
      expect(listed.single['variables'], [
        {'name': 'SCOPE', 'required': true, 'description': 'What to review'},
        {'name': 'DEPTH', 'required': false, 'description': 'How deep to look', 'default': 'shallow'},
      ]);
    });

    test('an empty catalog answers with an empty list rather than an error', () async {
      final result = toolResult(
        await callTool(passingHandler(definitions: InMemoryDefinitionSource(const [])), 'workflow_list'),
      );

      expect(result['isError'], isNull);
      expect(resultPayload(result)['workflows'], isEmpty);
    });
  });

  group('negative control: a guard block refuses both tools with no side effect', () {
    test('both are JSON-RPC successes carrying isError, with one block entry each and nothing started', () async {
      final handler = handlerWith(
        chain: GuardChain(guards: [FakeGuard.block('mcp workflow tools disabled')]),
        sink: audit,
      );

      const argumentsByTool = <String, Map<String, dynamic>>{
        'workflow_run': {
          'definition': 'nightly-review',
          'variables': {'SCOPE': 'inbox'},
        },
        'workflow_list': <String, dynamic>{},
      };

      for (final name in argumentsByTool.keys) {
        final result = toolResult(await callTool(handler, name, arguments: argumentsByTool[name]!));
        expect(result['isError'], isTrue, reason: '$name must refuse as a tool error, not a protocol error');
        expect(resultText(result), 'mcp workflow tools disabled');
      }

      expect(workflows.calls, isEmpty, reason: 'a blocked dispatch never reaches the workflow service');
      expect(workflows.activeRuns, isEmpty);
      expect(audit.entries.map((entry) => (entry.tool, entry.decision, entry.verdict)), [
        ('workflow_run', 'deny', 'block'),
        ('workflow_list', 'deny', 'block'),
      ]);
    });
  });

  group('the declared argument contract is enforced for workflow_run', () {
    // One row per validator branch workflow_run's schema can reach: a missing
    // required property, a blank string, a wrong declared type, and a free-keyed
    // object whose values are not the declared element type.
    const cases = <({Map<String, dynamic> arguments, String message})>[
      (arguments: {}, message: 'definition is required'),
      (arguments: {'definition': '  '}, message: 'definition must be a non-empty string'),
      (arguments: {'definition': 'nightly-review', 'variables': 'SCOPE=inbox'}, message: 'variables must be an object'),
      (
        arguments: {
          'definition': 'nightly-review',
          'variables': {'SCOPE': 3},
        },
        message: 'variables values must be strings',
      ),
    ];

    for (final testCase in cases) {
      test('workflow_run: ${testCase.message}', () async {
        final result = toolResult(await callTool(passingHandler(), 'workflow_run', arguments: testCase.arguments));

        expect(result['isError'], isTrue);
        expect(resultPayload(result)['reason'], 'invalid_request');
        expect(resultPayload(result)['message'], testCase.message);
        // Fail-closed means the refused call also started nothing.
        expect(workflows.startCalls, 0);
        expect(workflows.activeRuns, isEmpty);
      });
    }
  });
}
