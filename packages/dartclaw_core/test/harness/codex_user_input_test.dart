import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/src/bridge/bridge_events.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

CodexHarness _harness(FakeCodexProcess process) => CodexHarness(
  cwd: '/tmp',
  processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
  commandProbe: defaultCommandProbe,
  delayFactory: noOpDelay,
  environment: const {'OPENAI_API_KEY': 'sk-test-key'},
);

Map<String, dynamic> _item(String id, {Object? questions, String text = 'What next?', String? delivery}) => {
  'type': 'agentMessage',
  'id': id,
  'text': text,
  'phase': 'final_answer',
  'delivery': delivery,
  'questions': questions,
};

Map<String, dynamic> _frame(String method, Map<String, dynamic> params, {Object? id}) => {
  'id': ?id,
  'method': method,
  'params': params,
};

void _send(CodexHarness harness, Map<String, dynamic> frame) => harness.handleProcessStdoutLine(jsonEncode(frame));

void main() {
  late Level previousLevel;
  late List<LogRecord> warnings;

  setUp(() {
    previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    warnings = [];
  });
  tearDown(() => Logger.root.level = previousLevel);

  test('user input override is sent at process spawn without changing existing config', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    late List<String> args;
    final harness = CodexHarness(
      cwd: '/tmp',
      processFactory: (exe, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
        args = List<String>.from(arguments);
        return process;
      },
      commandProbe: defaultCommandProbe,
      delayFactory: noOpDelay,
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
    );
    addTearDown(harness.dispose);
    await startHarness(harness, process);
    expect(args, containsAllInOrder(['-c', 'tools.experimental_request_user_input.enabled=false']));
    expect(args, contains('app-server'));
    expect(args, isNot(contains('--yolo')));
  });

  test('user input override rejection surfaces without a permissive retry', () async {
    var attempts = 0;
    final harness = CodexHarness(
      cwd: '/tmp',
      processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
        attempts++;
        expect(args, contains('tools.experimental_request_user_input.enabled=false'));
        throw ProcessException(exe, args, 'unrecognized config override');
      },
      commandProbe: defaultCommandProbe,
      delayFactory: noOpDelay,
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
    );
    addTearDown(harness.dispose);
    await expectLater(harness.start(), throwsA(isA<ProcessException>()));
    expect(attempts, 1);
  });

  test('probes the configured Codex binary directly', () async {
    final calls = <({String executable, List<String> arguments})>[];
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = CodexHarness(
      cwd: '/tmp',
      processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      commandProbe: (executable, arguments) async {
        calls.add((executable: executable, arguments: arguments));
        return ProcessResult(0, 0, 'C:\\Program Files\\Codex\\codex.exe\r\n', '');
      },
      delayFactory: noOpDelay,
      platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
    );
    addTearDown(harness.dispose);
    await startHarness(harness, process);
    expect(calls.single.executable, 'codex');
    expect(calls.single.arguments, ['--version']);
  });

  test('converts a thrown Codex probe failure to a structured lookup error', () async {
    final harness = CodexHarness(
      cwd: '/tmp',
      commandProbe: (_, _) async => throw ProcessException('codex', ['--version'], 'probe failed'),
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
    );
    addTearDown(harness.dispose);
    await expectLater(
      harness.start(),
      throwsA(isA<UnsupportedCapabilityError>().having((e) => e.attemptedContext, 'context', 'codex --version')),
    );
  });

  test('user input transport instructions accompany empty and nonempty caller prompts once', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    await startHarness(harness, process);
    for (final (session, prompt) in [('empty', ''), ('caller', 'Caller instructions')]) {
      final turn = harness.turn(
        sessionId: session,
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: prompt,
      );
      await respondToLatestThreadStart(process, threadId: '$session-thread');
      process.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turn;
    }
    final starts = process.sentMessages.where((message) => message['method'] == 'thread/start').toList();
    expect(starts, hasLength(2));
    for (final start in starts) {
      final instructions = (start['params'] as Map<String, dynamic>)['developerInstructions'] as String;
      expect('DartClaw cannot collect answers'.allMatches(instructions), hasLength(1));
      expect(instructions, contains('final reply'));
      expect(instructions, contains('queued acknowledgement'));
    }
    expect((starts.last['params'] as Map<String, dynamic>)['developerInstructions'], startsWith('Caller instructions'));
  });

  test('captured async question warns once while its question-only final text survives', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    final subscription = Logger('CodexHarness').onRecord.listen(warnings.add);
    addTearDown(subscription.cancel);
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'captured',
      messages: const [
        {'role': 'user', 'content': 'ask one question'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process, threadId: '01a0e69f-ae33-77b0-b33a-1354927196e9');
    _send(
      harness,
      _frame('turn/started', {
        'threadId': '01a0e69f-ae33-77b0-b33a-1354927196e9',
        'turn': {'id': '01a0e69f-ae54-7e82-accb-557fbeca3643'},
      }),
    );
    final relative = p.join('test', 'harness', 'fixtures', 'codex_user_input_disabled_frames.jsonl');
    final file = File(relative).existsSync() ? File(relative) : File(p.join('packages', 'dartclaw_core', relative));
    for (final line in file.readAsLinesSync()) {
      harness.handleProcessStdoutLine(line);
    }
    final result = await turn;
    expect(result.finalText, contains('Which color do you prefer?'));
    expect(warnings.where((record) => record.message.contains('Unsupported Codex user input')), hasLength(1));
    final diagnostic = warnings.singleWhere((record) => record.message.contains('Unsupported Codex user input'));
    expect(diagnostic.message, contains('Blue (Recommended)'));
    expect(diagnostic.message, contains('No answer was supplied through DartClaw'));
  });

  test('later final text does not erase question warning, and summary-only question warns', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    final subscription = Logger('CodexHarness').onRecord.listen(warnings.add);
    addTearDown(subscription.cancel);
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'later',
      messages: const [
        {'role': 'user', 'content': 'ask one question'},
      ],
      systemPrompt: 'caller',
    );
    await respondToLatestThreadStart(process);
    _send(
      harness,
      _frame('turn/started', {
        'threadId': 'thread-123',
        'turn': {'id': 'turn-1'},
      }),
    );
    final question = _item(
      'question-1',
      questions: [
        {
          'title': 'Pick a color?',
          'options': ['Blue', 'Green'],
        },
      ],
    )..['phase'] = 'commentary';
    _send(harness, _frame('item/completed', {'threadId': 'thread-123', 'turnId': 'turn-1', 'item': question}));
    _send(
      harness,
      _frame('turn/completed', {
        'threadId': 'thread-123',
        'turn': {
          'id': 'turn-1',
          'status': 'completed',
          'items': [question, _item('final', text: 'The final answer.', questions: null)],
        },
      }),
    );
    expect((await turn).finalText, 'The final answer.');
    expect(warnings.where((record) => record.message.contains('Unsupported Codex user input')), hasLength(1));

    final second = harness.turn(
      sessionId: 'later',
      messages: const [
        {'role': 'user', 'content': 'again'},
      ],
      systemPrompt: 'caller',
    );
    _send(
      harness,
      _frame('turn/started', {
        'threadId': 'thread-123',
        'turn': {'id': 'turn-2'},
      }),
    );
    _send(
      harness,
      _frame('turn/completed', {
        'threadId': 'thread-123',
        'turn': {
          'id': 'turn-2',
          'status': 'completed',
          'items': [question],
        },
      }),
    );
    await second;
    expect(warnings.where((record) => record.message.contains('Unsupported Codex user input')), hasLength(2));
  });

  test('valid question after malformed started frame warns once across completion and summary', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    final subscription = Logger('CodexHarness').onRecord.listen(warnings.add);
    addTearDown(subscription.cancel);
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'recovered-question',
      messages: const [
        {'role': 'user', 'content': 'Ask a question'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    _send(
      harness,
      _frame('turn/started', {
        'threadId': 'thread-123',
        'turn': {'id': 'turn-1'},
      }),
    );
    final malformed = _item(
      'question-1',
      questions: [
        {
          'title': '',
          'options': ['Blue'],
        },
      ],
    );
    final valid = _item(
      'question-1',
      questions: [
        {
          'title': 'Pick a color?',
          'options': ['Blue', 'Green'],
        },
      ],
    );
    _send(harness, _frame('item/started', {'threadId': 'thread-123', 'turnId': 'turn-1', 'item': malformed}));
    _send(harness, _frame('item/completed', {'threadId': 'thread-123', 'turnId': 'turn-1', 'item': valid}));
    _send(
      harness,
      _frame('turn/completed', {
        'threadId': 'thread-123',
        'turn': {
          'id': 'turn-1',
          'status': 'completed',
          'items': [valid],
        },
      }),
    );
    await turn;
    expect(warnings.where((record) => record.message.contains('Malformed Codex user input')), hasLength(1));
    final validWarnings = warnings.where((record) => record.message.contains('Unsupported Codex user input')).toList();
    expect(validWarnings, hasLength(1));
    expect(validWarnings.single.message, contains('Pick a color?'));
    expect(validWarnings.single.message, contains('Blue'));
  });

  test('request/response question warns and receives unsupported error without approval wait', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    final subscription = Logger('CodexHarness').onRecord.listen(warnings.add);
    addTearDown(subscription.cancel);
    final events = <BridgeEvent>[];
    final eventSubscription = harness.events.listen(events.add);
    addTearDown(eventSubscription.cancel);
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'request',
      messages: const [
        {'role': 'user', 'content': 'ask one question'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    _send(
      harness,
      _frame('turn/started', {
        'threadId': 'thread-123',
        'turn': {'id': 'turn-1'},
      }),
    );
    for (final (requestId, blocking) in [(73, false), (74, true)]) {
      _send(
        harness,
        _frame('item/tool/requestUserInput', {
          'threadId': 'thread-123',
          'turnId': 'turn-1',
          'itemId': 'question-$requestId',
          'isBlocking': blocking,
          'questions': [
            {
              'title': 'Pick a color?',
              'options': ['Blue', 'Green'],
            },
          ],
        }, id: requestId),
      );
    }
    await Future<void>.delayed(Duration.zero);
    for (final requestId in [73, 74]) {
      expect(process.sentMessages.singleWhere((message) => message['id'] == requestId)['error'], {
        'code': -32601,
        'message': 'Method not supported by DartClaw',
      });
    }
    expect(warnings.where((record) => record.message.contains('Unsupported Codex user input')), hasLength(2));
    expect(events.whereType<ToolApprovalWaitEvent>(), isEmpty);
    process.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
    await turn;
  });

  test('prose, malformed metadata and other thread notifications do not invent a question', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    final subscription = Logger('CodexHarness').onRecord.listen(warnings.add);
    addTearDown(subscription.cancel);
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'malformed',
      messages: const [
        {'role': 'user', 'content': 'test'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    _send(
      harness,
      _frame('turn/started', {
        'threadId': 'thread-123',
        'turn': {'id': 'turn-1'},
      }),
    );
    for (final item in [
      _item('plain', text: 'Should I ask?', delivery: 'async'),
      _item(
        'broken',
        questions: [
          {
            'title': '',
            'options': ['Blue'],
          },
        ],
      ),
    ]) {
      _send(harness, _frame('item/completed', {'threadId': 'thread-123', 'turnId': 'turn-1', 'item': item}));
    }
    _send(
      harness,
      _frame('item/completed', {
        'threadId': 'child-thread',
        'turnId': 'child-turn',
        'item': _item(
          'child',
          questions: [
            {
              'title': 'Child?',
              'options': ['Yes'],
            },
          ],
        ),
      }),
    );
    _send(
      harness,
      _frame('item/completed', {
        'threadId': 'thread-123',
        'turnId': 'earlier-turn',
        'item': _item(
          'earlier',
          questions: [
            {
              'title': 'Earlier?',
              'options': ['Yes'],
            },
          ],
        ),
      }),
    );
    process.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
    await turn;
    expect(warnings.where((record) => record.message.contains('Unsupported Codex user input')), isEmpty);
    expect(warnings.where((record) => record.message.contains('Malformed Codex user input')), hasLength(1));
    expect(
      warnings.singleWhere((record) => record.message.contains('Malformed Codex user input')).message,
      isNot(contains('Blue')),
    );
  });

  test('a provider error after a question remains an error with no fabricated completion', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    final subscription = Logger('CodexHarness').onRecord.listen(warnings.add);
    addTearDown(subscription.cancel);
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'failed',
      messages: const [
        {'role': 'user', 'content': 'test'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    _send(
      harness,
      _frame('turn/started', {
        'threadId': 'thread-123',
        'turn': {'id': 'turn-1'},
      }),
    );
    _send(
      harness,
      _frame('item/completed', {
        'threadId': 'thread-123',
        'turnId': 'turn-1',
        'item': _item(
          'question',
          questions: [
            {
              'title': 'Proceed?',
              'options': ['Yes'],
            },
          ],
        ),
      }),
    );
    _send(
      harness,
      _frame('turn/failed', {
        'threadId': 'thread-123',
        'turnId': 'turn-1',
        'error': {'message': 'provider failed'},
      }),
    );
    final result = await turn;
    expect(result.stopReason, 'error');
    expect(result.finalText, isNull);
    expect(result.inputTokens, 0);
    expect(warnings.where((record) => record.message.contains('Unsupported Codex user input')), hasLength(1));
  });

  test('a delayed prior-turn question cannot claim the next active turn', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _harness(process);
    addTearDown(harness.dispose);
    final subscription = Logger('CodexHarness').onRecord.listen(warnings.add);
    addTearDown(subscription.cancel);
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'next-turn',
      messages: const [
        {'role': 'user', 'content': 'new turn'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    _send(
      harness,
      _frame('item/completed', {
        'threadId': 'thread-123',
        'turnId': 'prior-turn',
        'item': _item(
          'stale-question',
          questions: [
            {
              'title': 'Prior question?',
              'options': ['Yes'],
            },
          ],
        ),
      }),
    );
    _send(
      harness,
      _frame('turn/started', {
        'threadId': 'thread-123',
        'turn': {'id': 'current-turn'},
      }),
    );
    _send(
      harness,
      _frame('turn/completed', {
        'threadId': 'thread-123',
        'turn': {
          'id': 'current-turn',
          'status': 'completed',
          'items': [
            {'type': 'agentMessage', 'phase': 'final_answer', 'text': 'Current answer.'},
          ],
        },
      }),
    );
    expect((await turn).finalText, 'Current answer.');
    expect(warnings.where((record) => record.message.contains('Unsupported Codex user input')), isEmpty);
  });
}
