import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/api_workflow_connection.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_digest.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowRun, WorkflowStep;
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

void main() {
  test('digest retains null and zero step usage with an incomplete run lower bound after reload', () {
    final definition = WorkflowDefinition(
      name: 'accounting',
      description: 'Account for both steps',
      steps: const [
        WorkflowStep(id: 'unknown', name: 'Unknown', prompts: ['a']),
        WorkflowStep(id: 'zero', name: 'Zero', prompts: ['b']),
      ],
    );
    final now = DateTime.utc(2026, 6, 1);
    final saved = WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.completed,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 2,
      totalTokens: 0,
      tokenUsageComplete: false,
      definitionJson: definition.toJson(),
      contextJson: const {
        'data': {
          'unknown.status': 'success',
          'unknown.tokenCount': null,
          'zero.status': 'success',
          'zero.tokenCount': 0,
        },
      },
    );
    final run = WorkflowRun.fromJson(saved.toJson());
    final digest = buildWorkflowRunDigest(
      commandPrefix: 'dartclaw workflow',
      run: run,
      definition: definition,
      childTasks: const [],
    );

    expect(digest.toJson()['tokenUsageComplete'], false);
    expect(digest.toJson()['totalTokens'], 0);
    expect(digest.rows[0].toJson()['tokens'], isNull);
    expect(digest.rows[1].toJson()['tokens'], 0);
    final lines = renderWorkflowRunDigestLines(digest).join('\n');
    expect(lines, contains('0 (incomplete lower bound)'));
    expect(lines, contains('tokens unavailable'));
    expect(lines, contains('0 tokens'));
  });

  test('connected status labels persisted incomplete usage', () async {
    final transport = FakeApiTransport(
      sendResponses: [
        jsonResponse(200, {
          'id': 'run-1',
          'definitionName': 'accounting',
          'status': 'completed',
          'startedAt': '2026-06-01T10:00:00Z',
          'totalTokens': 0,
          'tokenUsageComplete': false,
          'steps': [
            {'id': 'unknown', 'name': 'Unknown', 'status': 'completed', 'tokenCount': null},
            {'id': 'zero', 'name': 'Zero', 'status': 'completed', 'tokenCount': 0},
            {'id': 'skip', 'name': 'Skip', 'status': 'skipped', 'tokenCount': null},
            {'id': 'pending', 'name': 'Pending', 'status': 'pending', 'tokenCount': null},
          ],
        }),
      ],
    );
    final output = <String>[];
    final command = WorkflowStatusCommand(
      connection: ApiWorkflowConnection(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
      ),
      writeLine: output.add,
      exitFn: fakeExit,
    );
    await (CommandRunner<void>('dartclaw', 'test')..addCommand(command)).run(['status', 'run-1']);

    expect(output.join('\n'), contains('Tokens:      0 (incomplete lower bound)'));
    expect(output.singleWhere((line) => line.contains('Unknown')), contains('unavailable'));
    expect(output.singleWhere((line) => line.contains('Zero')), contains('  0'));
    expect(output.singleWhere((line) => line.contains('Skip')), contains('  0'));
    expect(output.singleWhere((line) => line.contains('Pending')), contains('  —'));
  });
}
