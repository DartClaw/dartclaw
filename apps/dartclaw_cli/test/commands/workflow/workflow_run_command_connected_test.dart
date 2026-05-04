import 'dart:collection';
import 'dart:convert';
import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowDefinition, WorkflowStep;
import 'package:test/test.dart';

class _FakeExit implements Exception {
  final int code;
  const _FakeExit(this.code);
}

Never _fakeExit(int code) => throw _FakeExit(code);

void main() {
  group('WorkflowRunCommand connected mode', () {
    test('connected run exits 0 after terminal SSE event', () async {
      final transport = _FakeTransport(
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
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        stdoutLine: output.add,
        stderrLine: errorOutput.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow']),
        throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.any((line) => line.contains('Starting: demo-workflow')), isTrue);
      expect(output.any((line) => line.contains('Completed: 1/1 steps')), isTrue);
      expect(errorOutput, isEmpty);
      expect(transport.requests.first.uri.path, '/api/workflows/run');
      expect(transport.requests.last.uri.path, '/api/workflows/runs/run-1/events');
    });

    test('standalone mode aborts when a server is reachable without --force', () async {
      final transport = _FakeTransport(
        sendResponses: [
          _jsonResponse(200, {'ok': true}),
        ],
      );
      final errorOutput = <String>[];
      final command = WorkflowRunCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        stderrLine: errorOutput.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--standalone']),
        throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(errorOutput.single, contains('Use connected mode or add --force to override'));
    });

    test('connected json mode prints structured event lines', () async {
      final transport = _FakeTransport(
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
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        stdoutLine: output.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'demo-workflow', '--json']),
        throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.first, contains('"type":"run_started"'));
      expect(output.last, contains('"type":"workflow_status_changed"'));
    });

    test('interrupt sends cancel request and exits 2 after cancelled event', () async {
      final sseController = StreamController<List<int>>();
      final interruptController = StreamController<void>();
      final transport = _FakeTransport(
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
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        stdoutLine: output.add,
        exitFn: _fakeExit,
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

      await expectLater(() => future, throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 2)));

      expect(transport.requests.map((request) => request.uri.path), contains('/api/workflows/runs/run-1/cancel'));
      expect(output.any((line) => line.contains('Cancelling')), isTrue);
      await interruptController.close();
    });
  });
}

Map<String, dynamic> _startedRunJson() {
  final definition = WorkflowDefinition(
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
    'definitionName': definition.name,
    'status': 'running',
    'contextJson': <String, dynamic>{},
    'variablesJson': <String, String>{},
    'startedAt': now,
    'updatedAt': now,
    'totalTokens': 0,
    'currentStepIndex': 0,
    'definitionJson': definition.toJson(),
  };
}

class _FakeTransport implements ApiTransport {
  final Queue<ApiResponse> _sendResponses;
  final Queue<ApiResponse> _streamResponses;
  final List<ApiRequest> requests = <ApiRequest>[];

  _FakeTransport({List<ApiResponse> sendResponses = const [], List<ApiResponse> streamResponses = const []})
    : _sendResponses = Queue<ApiResponse>.of(sendResponses),
      _streamResponses = Queue<ApiResponse>.of(streamResponses);

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    requests.add(request);
    return _sendResponses.removeFirst();
  }

  @override
  Future<ApiResponse> openStream(ApiRequest request) async {
    requests.add(request);
    return _streamResponses.removeFirst();
  }
}

ApiResponse _jsonResponse(int statusCode, Object body) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: Stream.value(utf8.encode(jsonEncode(body))),
  );
}
