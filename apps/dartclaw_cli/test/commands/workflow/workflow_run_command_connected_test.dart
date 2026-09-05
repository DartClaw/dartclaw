import 'package:dartclaw_cli/src/commands/workflow/api_workflow_connection.dart';

import 'dart:convert';
import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowStep;
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

void main() {
  group('WorkflowRunCommand connected mode', () {
    for (final (status, expectedExit) in [(403, 4), (503, 6)]) {
      test('stream HTTP $status preserves its exit class after a running refresh', () async {
        final transport = FakeApiTransport(
          sendResponses: [_jsonResponse(201, _startedRunJson()), _jsonResponse(200, _startedRunJson())],
          streamResponses: [
            _jsonResponse(status, {
              'error': {'code': 'STREAM_FAILED', 'message': 'Stream unavailable'},
            }),
          ],
        );
        final errors = <String>[];
        final runner = CommandRunner<void>('dartclaw', 'test')
          ..addCommand(
            WorkflowRunCommand(
              connection: ApiWorkflowConnection(
                apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
              ),
              stdoutLine: (_) {},
              stderrLine: errors.add,
              exitFn: fakeExit,
            ),
          );
        await expectLater(
          runner.run(['run', 'demo-workflow']),
          throwsA(isA<FakeExit>().having((e) => e.code, 'code', expectedExit)),
        );
        expect(errors.single, 'Stream unavailable Use `dartclaw status run-1` to inspect the run.');
      });
    }

    test('connection refused exits 3 and retains the standalone hint', () async {
      final output = <String>[];
      final errors = <String>[];
      final runner = CommandRunner<void>('dartclaw', 'test')
        ..addCommand(
          WorkflowRunCommand(
            connection: ApiWorkflowConnection(
              apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: _RefusedTransport()),
            ),
            stdoutLine: output.add,
            stderrLine: errors.add,
            exitFn: fakeExit,
          ),
        );
      await expectLater(
        runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 3)),
      );
      expect(output, isEmpty);
      expect(errors.single, allOf(startsWith('Connection refused.'), contains('--standalone')));
    });

    test('connected run exits 0 after terminal SSE event', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"task_status_changed","taskId":"task-1","stepIndex":0,"oldStatus":"queued","newStatus":"running"}\n\n'
                'data: {"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0,"totalSteps":1,"taskId":"task-1","success":true,"tokenCount":12}\n\n'
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final errorOutput = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        stderrLine: errorOutput.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.any((line) => line.contains('Starting: demo-workflow')), isTrue);
      expect(output.any((line) => line.contains('Completed: 1/1 steps')), isTrue);
      expect(errorOutput, isEmpty);
      expect(transport.requests.first.uri.path, '/api/workflows/run');
      expect(transport.requests.last.uri.path, '/api/workflows/runs/run-1/events');
    });

    test('connected run skips a malformed SSE frame instead of aborting the stream', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                // Missing required taskId/totalSteps – must be skipped, not thrown.
                'data: {"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0}\n\n'
                'data: {"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0,"totalSteps":1,"taskId":"task-1","success":true,"tokenCount":12}\n\n'
                // Unknown status value (version skew) – must also be skipped.
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"nonexistent"}\n\n'
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final errorOutput = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        stderrLine: errorOutput.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.any((line) => line.contains('Completed: 1/1 steps')), isTrue);
      expect(errorOutput, isEmpty);
    });

    test('connected run sends approvals override in the start request', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: (_) {},
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--approvals=auto-on-stall']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      final body = jsonDecode(transport.requests.first.body!) as Map<String, dynamic>;
      expect(body['approvals'], 'auto-on-stall');
    });

    test('connected run forwards --inline without implying allow-dirty-localpath', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: (_) {},
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--inline']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      final body = jsonDecode(transport.requests.first.body!) as Map<String, dynamic>;
      expect(body['inline'], isTrue);
      // S05 [OC01]: --inline only changes git strategy; it must not imply
      // --allow-dirty-localpath.
      expect(body.containsKey('allowDirtyLocalPath'), isFalse);
    });

    test('connected text mode includes display scope from SSE events', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"task_status_changed","taskId":"task-1","stepIndex":0,"displayScope":"S01","oldStatus":"queued","newStatus":"running"}\n\n'
                'data: {"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0,"totalSteps":1,"taskId":"task-1","displayScope":"S01","success":true,"tokenCount":12}\n\n'
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output, contains('[step 1/1] step-1[S01]: First step – running'));
      expect(output, contains('[step 1/1] step-1[S01]: completed (0s, 12 tokens)'));
    });

    test('connected text mode renders needsInput as recoverable blocked', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0,"totalSteps":1,"taskId":"task-1","success":false,"outcome":"needsInput","reason":"waiting on operator","tokenCount":0}\n\n'
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"paused","errorMessage":"waiting on operator"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 2)),
      );

      expect(output, contains('[step 1/1] step-1: blocked (recoverable): waiting on operator'));
      expect(output, isNot(contains('[step 1/1] step-1: failed')));
    });

    test('connected text mode renders cancelled steps as resumable interruptions', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0,"totalSteps":1,"taskId":"task-1","success":false,"outcome":"cancelled","reason":"run teardown","tokenCount":0}\n\n'
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"cancelled"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 2)),
      );

      expect(output, contains('[step 1/1] step-1: interrupted (resumable): run teardown'));
      expect(output, isNot(contains('[step 1/1] step-1: failed')));
    });

    test('connected text mode renders direct map iteration completion with item id', () async {
      final definition = WorkflowDefinition(
        name: 'map-workflow',
        description: 'Map demo',
        steps: const [
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Do {{map.item.id}}'], mapOver: 'stories'),
        ],
        variables: const {},
      );
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson(definition: definition))],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"task_status_changed","taskId":"task-1","stepIndex":0,"displayScope":"S01","oldStatus":"queued","newStatus":"running"}\n\n'
                'data: {"type":"map_iteration_completed","runId":"run-1","stepId":"implement","iterationIndex":0,"totalIterations":1,"itemId":"S01","taskId":"task-1","success":true,"tokenCount":42}\n\n'
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'map-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output, contains('[step 1/1] implement[S01]: Implement – running'));
      expect(output, contains('[step 1/1] implement[S01]: completed (0s, 42 tokens)'));
    });

    test('connected text mode renders taskless foreach iteration cancellation with item id', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-workflow',
        description: 'Foreach demo',
        steps: const [
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            taskType: WorkflowTaskType.foreach,
            prompts: [],
            mapOver: 'stories',
            foreachSteps: ['implement'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Do {{map.item.id}}']),
        ],
        variables: const {},
      );
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson(definition: definition))],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"map_iteration_completed","runId":"run-1","stepId":"story-pipeline","iterationIndex":1,"totalIterations":2,"itemId":"S02","taskId":"","success":false,"outcome":"cancelled","reason":"run teardown","tokenCount":0}\n\n'
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'foreach-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output, contains('[step 1/2] story-pipeline[S02]: interrupted (resumable): run teardown'));
    });

    test('standalone mode aborts when a server is reachable without --force', () async {
      final errorOutput = <String>[];
      final command = WorkflowRunCommand(
        reachabilityProbe: (_) async => true,
        stderrLine: errorOutput.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--standalone']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(errorOutput.single, contains('Use connected mode or add --force to override'));
    });

    test('connected json mode prints structured event lines', () async {
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(
              utf8.encode(
                'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}\n\n',
              ),
            ),
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--json']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.first, contains('"type":"run_started"'));
      expect(output.last, contains('"type":"workflow_status_changed"'));
    });

    // TI01 parity pin: the connected lane's --json stream is the server's frames
    // verbatim, in order. Enumerating the sequence (rather than asserting
    // `contains` per type) is what makes a dropped, added or reordered frame
    // detectable at all.
    test('TI01 connected json mode echoes every server frame in order, unmodified', () async {
      final started = _startedRunJson();
      final frames = <String>[
        '{"type":"task_status_changed","taskId":"task-1","stepIndex":0,"displayScope":"S01","oldStatus":"queued","newStatus":"running"}',
        '{"type":"workflow_cli_turn_progress","taskId":"task-1","cumulativeTokens":42}',
        // Rendered on neither lane – echoed, but printing nothing.
        '{"type":"parallel_group_completed","runId":"run-1","stepId":"step-1","memberCount":2}',
        // Malformed (missing totalSteps/taskId/success/tokenCount) – skipped, but echoed first.
        '{"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0}',
        '{"type":"task_status_changed","taskId":"task-1","stepIndex":0,"oldStatus":"running","newStatus":"accepted"}',
        '{"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0,"totalSteps":1,"taskId":"task-1","displayScope":"S01","success":true,"outcome":"succeeded","tokenCount":12}',
        '{"type":"future_frame_the_cli_does_not_know","runId":"run-1"}',
        '{"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed","totalTokens":12,"currentStepIndex":1}',
      ];
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, started)],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(utf8.encode(frames.map((frame) => 'data: $frame\n\n').join())),
          ),
        ],
      );
      final output = <String>[];
      final errorOutput = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        stderrLine: errorOutput.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--json']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output, [
        jsonEncode({'type': 'run_started', 'run': started}),
        ...frames,
      ]);
      expect(errorOutput, isEmpty);
    });

    // TI01 parity pin: the connected lane's text output, enumerated in order.
    test('TI01 connected text mode emits the full ordered stdout', () async {
      final frames = <String>[
        '{"type":"task_status_changed","taskId":"task-1","stepIndex":0,"displayScope":"S01","oldStatus":"queued","newStatus":"running"}',
        // stepIndex past the definition's step count – skipped, never a RangeError.
        '{"type":"task_status_changed","taskId":"task-9","stepIndex":7,"oldStatus":"queued","newStatus":"running"}',
        '{"type":"task_status_changed","taskId":"task-1","stepIndex":0,"displayScope":"S01","oldStatus":"running","newStatus":"review"}',
        '{"type":"parallel_group_completed","runId":"run-1","stepId":"step-1","memberCount":2}',
        '{"type":"task_status_changed","taskId":"task-1","stepIndex":0,"oldStatus":"review","newStatus":"accepted"}',
        '{"type":"workflow_step_completed","runId":"run-1","stepId":"step-1","stepIndex":0,"totalSteps":1,"taskId":"task-1","displayScope":"S01","success":true,"outcome":"succeeded","tokenCount":12}',
        '{"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed","totalTokens":12,"currentStepIndex":1}',
      ];
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(utf8.encode(frames.map((frame) => 'data: $frame\n\n').join())),
          ),
        ],
      );
      final output = <String>[];
      final errorOutput = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        stderrLine: errorOutput.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output, [
        '[workflow] Starting: demo-workflow (1 steps)',
        '[step 1/1] step-1[S01]: First step – running',
        '[step 1/1] step-1[S01]: review (auto-accepted)',
        '[step 1/1] step-1[S01]: completed (0s, 12 tokens)',
        '[workflow] Completed: 1/1 steps (0s, 12 tokens)',
      ]);
      expect(errorOutput, isEmpty);
    });

    // A version-skewed field shape must be as survivable as a malformed frame
    // (S05): the run settles normally instead of dying on an uncaught cast.
    test('connected run survives a skewed field shape in a frame it renders', () async {
      final frames = <String>[
        // Settling transition whose stepIndex arrives as a string.
        '{"type":"task_status_changed","taskId":"task-1","stepIndex":"0","oldStatus":"running","newStatus":"accepted"}',
        // Non-integer cumulative token count.
        '{"type":"workflow_cli_turn_progress","taskId":"task-1","cumulativeTokens":12.5}',
        '{"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed","totalTokens":12}',
      ];
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, _startedRunJson())],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(utf8.encode(frames.map((frame) => 'data: $frame\n\n').join())),
          ),
        ],
      );
      final output = <String>[];
      final errorOutput = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        stderrLine: errorOutput.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output, [
        '[workflow] Starting: demo-workflow (1 steps)',
        '[workflow] Completed: 1/1 steps (0s, 12 tokens)',
      ]);
      expect(errorOutput, isEmpty);
    });

    test('connected json mode echoes a skewed frame and still settles', () async {
      final frames = <String>[
        '{"type":"workflow_cli_turn_progress","taskId":"task-1","cumulativeTokens":12.5}',
        '{"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"completed"}',
      ];
      final started = _startedRunJson();
      final transport = FakeApiTransport(
        sendResponses: [_jsonResponse(201, started)],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: Stream.value(utf8.encode(frames.map((frame) => 'data: $frame\n\n').join())),
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--json']),
        throwsA(isA<FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output, [
        jsonEncode({'type': 'run_started', 'run': started}),
        ...frames,
      ]);
    });

    test('interrupt sends cancel request and exits 2 after cancelled event', () async {
      final sseController = StreamController<List<int>>();
      final interruptController = StreamController<void>();
      final transport = FakeApiTransport(
        sendResponses: [
          _jsonResponse(201, _startedRunJson()),
          ApiResponse(statusCode: 204, headers: const {}, body: const Stream.empty()),
        ],
        streamResponses: [
          ApiResponse(
            statusCode: 200,
            headers: const {'content-type': 'text/event-stream'},
            body: sseController.stream,
          ),
        ],
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        connection: ApiWorkflowConnection(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        ),
        stdoutLine: output.add,
        exitFn: fakeExit,
        interrupts: () => interruptController.stream,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      final future = runner.run(['run', 'demo-workflow']);
      await Future<void>.delayed(Duration.zero);
      interruptController.add(null);
      sseController.add(
        utf8.encode(
          'data: {"type":"workflow_status_changed","runId":"run-1","oldStatus":"running","newStatus":"cancelled"}\n\n',
        ),
      );
      await sseController.close();

      await expectLater(() => future, throwsA(isA<FakeExit>().having((e) => e.code, 'code', 2)));

      expect(transport.requests.map((request) => request.uri.path), contains('/api/workflows/runs/run-1/cancel'));
      expect(output.any((line) => line.contains('Cancelling')), isTrue);
      await interruptController.close();
    });
  });
}

Map<String, dynamic> _startedRunJson({WorkflowDefinition? definition}) {
  final resolvedDefinition =
      definition ??
      WorkflowDefinition(
        name: 'demo-workflow',
        description: 'Demo',
        steps: const [
          WorkflowStep(id: 'step-1', name: 'First step', prompts: ['Do the work']),
        ],
        variables: const {},
      );
  final now = DateTime.utc(2026, 1, 1, 12).toIso8601String();
  return {
    'id': 'run-1',
    'definitionName': resolvedDefinition.name,
    'status': 'running',
    'contextJson': <String, dynamic>{},
    'variablesJson': <String, String>{},
    'startedAt': now,
    'updatedAt': now,
    'totalTokens': 0,
    'currentStepIndex': 0,
    'definitionJson': resolvedDefinition.toJson(),
  };
}

ApiResponse _jsonResponse(int statusCode, Object body) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: Stream.value(utf8.encode(jsonEncode(body))),
  );
}

class _RefusedTransport implements ApiTransport {
  @override
  Future<ApiResponse> send(ApiRequest request) async =>
      throw DartclawApiException('Connection refused.', code: 'CONNECTION_REFUSED');
  @override
  Future<ApiResponse> openStream(ApiRequest request) => throw StateError('No stream expected');
}
