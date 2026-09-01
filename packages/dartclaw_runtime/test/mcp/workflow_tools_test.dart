import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/workflow_tools.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGuard;
import 'package:dartclaw_workflow/testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowDefinitionSource, WorkflowRun, WorkflowStep, WorkflowVariable;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:dartclaw_runtime/src/task/workflow_start_precondition_exception.dart';

import '../api/workflow_test_support.dart';
import '../guard_audit_test_support.dart';

Future<Map<String, dynamic>> _call(
  McpProtocolHandler handler,
  String name, {
  Map<String, dynamic> arguments = const {},
}) async {
  final raw = await handler.handleRequest(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  return jsonDecode(raw!) as Map<String, dynamic>;
}

Map<String, dynamic> _result(Map<String, dynamic> response) {
  expect(response['error'], isNull, reason: 'a tool refusal must be a JSON-RPC success carrying isError');
  return response['result'] as Map<String, dynamic>;
}

String _text(Map<String, dynamic> result) =>
    ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;

Map<String, dynamic> _payload(Map<String, dynamic> result) => jsonDecode(_text(result)) as Map<String, dynamic>;

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
  late Database taskDb;
  late Database workflowDb;
  late TaskService tasks;
  late FakeWorkflowService workflows;
  late RecordingGuardAuditLogger audit;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_tools_');
    taskDb = openTaskDbInMemory();
    workflowDb = sqlite3.openInMemory();
    final eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(taskDb), eventBus: eventBus);
    workflows = FakeWorkflowService(db: workflowDb, taskService: tasks, eventBus: eventBus, dataDir: tempDir.path);
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
    taskDb.close();
    workflowDb.close();
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
      final payload = _payload(
        _result(
          await _call(
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

  group('S02 a missing required variable and an unknown definition are tool errors that start nothing', () {
    test('the missing variable is named, as invalid_variables, and no run is started', () async {
      final result = _result(
        await _call(passingHandler(), 'workflow_run', arguments: {'definition': 'nightly-review'}),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['reason'], 'invalid_variables');
      expect(_payload(result)['message'], 'Missing required variable(s): SCOPE');
      expect(workflows.activeRuns, isEmpty);
      expect(workflows.startCalls, 0);
    });

    test('an unregistered definition is named, as unknown_definition, and no run is started', () async {
      final result = _result(
        await _call(
          passingHandler(),
          'workflow_run',
          arguments: {
            'definition': 'ghost-review',
            'variables': {'SCOPE': 'inbox'},
          },
        ),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['reason'], 'unknown_definition');
      expect(_payload(result)['message'], 'No workflow definition named ghost-review');
      expect(_payload(result)['definition'], 'ghost-review');
      expect(workflows.activeRuns, isEmpty);
      expect(workflows.startCalls, 0);
    });
  });

  group('a start precondition the service refuses is a tool error too', () {
    test('WorkflowStartPreconditionException is reported as precondition_failed with no run started', () async {
      workflows.startError = const WorkflowStartPreconditionException('workspace has uncommitted changes');

      final result = _result(
        await _call(
          passingHandler(),
          'workflow_run',
          arguments: {
            'definition': 'nightly-review',
            'variables': {'SCOPE': 'inbox'},
          },
        ),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['reason'], 'precondition_failed');
      expect(_payload(result)['message'], 'workspace has uncommitted changes');
      expect(workflows.activeRuns, isEmpty);
    });
  });

  group('S03 workflow_list carries the variable contract', () {
    test('both variables are listed with their required flag, and only the optional one carries a default', () async {
      final payload = _payload(_result(await _call(passingHandler(), 'workflow_list')));
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
      final result = _result(
        await _call(passingHandler(definitions: InMemoryDefinitionSource(const [])), 'workflow_list'),
      );

      expect(result['isError'], isNull);
      expect(_payload(result)['workflows'], isEmpty);
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
        final result = _result(await _call(handler, name, arguments: argumentsByTool[name]!));
        expect(result['isError'], isTrue, reason: '$name must refuse as a tool error, not a protocol error');
        expect(_text(result), 'mcp workflow tools disabled');
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
        final result = _result(await _call(passingHandler(), 'workflow_run', arguments: testCase.arguments));

        expect(result['isError'], isTrue);
        expect(_payload(result)['reason'], 'invalid_request');
        expect(_payload(result)['message'], testCase.message);
        // Fail-closed means the refused call also started nothing.
        expect(workflows.startCalls, 0);
        expect(workflows.activeRuns, isEmpty);
      });
    }
  });
}
