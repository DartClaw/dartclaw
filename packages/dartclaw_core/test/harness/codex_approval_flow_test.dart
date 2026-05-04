import 'dart:convert';

import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

CodexHarness _buildHarness({
  required FakeCodexProcess process,
  GuardChain? guardChain,
  Map<String, String>? environment,
}) {
  return CodexHarness(
    cwd: '/tmp',
    executable: 'codex',
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
    commandProbe: defaultCommandProbe,
    delayFactory: noOpDelay,
    environment: environment ?? const {'OPENAI_API_KEY': 'sk-test-key'},
    guardChain: guardChain,
  );
}

class _RecordingGuard extends Guard {
  _RecordingGuard({this.verdict});

  final GuardVerdict? verdict;
  final contexts = <GuardContext>[];

  @override
  String get name => 'recording-guard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    contexts.add(context);
    return verdict ?? GuardVerdict.pass();
  }
}

class _ThrowingGuard extends Guard {
  @override
  String get name => 'throwing-guard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    throw StateError('guard exploded');
  }
}

void main() {
  group('CodexHarness approval flow', () {
    test('routes approval requests through GuardChain and allows approved tools', () async {
      final fake = FakeCodexProcess();
      final guard = _RecordingGuard();
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-allow',
        messages: [
          {'role': 'user', 'content': 'run status'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'allow-1',
        toolUseId: 'tool-1',
        toolName: 'command_execution',
        extraParams: {
          'tool_input': {'command': 'git status'},
        },
      );
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(guard.contexts, hasLength(1));
      expect(guard.contexts.single.toolName, 'shell');
      expect(guard.contexts.single.rawProviderToolName, 'command_execution');
      expect(guard.contexts.single.sessionId, 'sess-allow');
      expect(guard.contexts.single.toolInput, {'command': 'git status'});
      final allowResponse = fake.sentMessages.singleWhere((message) => message['id'] == 'allow-1');
      expect(allowResponse['jsonrpc'], '2.0');
      expect(allowResponse['result'], {'approved': true});
    });

    test('routes approval requests through GuardChain and denies blocked tools', () async {
      final fake = FakeCodexProcess();
      final guard = _RecordingGuard(verdict: GuardVerdict.block('Blocked by test guard'));
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-block',
        messages: [
          {'role': 'user', 'content': 'remove everything'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'deny-1',
        toolUseId: 'tool-2',
        toolName: 'command_execution',
        extraParams: {
          'tool_input': {'command': 'rm -rf /tmp/demo'},
        },
      );
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      final denyResponse = fake.sentMessages.singleWhere((message) => message['id'] == 'deny-1');
      expect(denyResponse['jsonrpc'], '2.0');
      expect(denyResponse['result'], {'approved': false, 'reason': 'Blocked by test guard'});
    });

    test('infers file_change kind before approval evaluation', () async {
      final fake = FakeCodexProcess();
      final guard = _RecordingGuard();
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-file-change',
        messages: [
          {'role': 'user', 'content': 'update files'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'file-create',
        toolUseId: 'tool-create',
        toolName: 'file_change',
        extraParams: {
          'tool_input': {'kind': 'create', 'path': '/tmp/new.txt'},
        },
      );
      fake.emitApprovalRequest(
        requestId: 'file-update',
        toolUseId: 'tool-update',
        toolName: 'file_change',
        extraParams: {
          'tool_input': {'kind': 'update', 'path': '/tmp/existing.txt'},
        },
      );
      fake.emitApprovalRequest(
        requestId: 'file-unknown',
        toolUseId: 'tool-unknown',
        toolName: 'file_change',
        extraParams: {
          'tool_input': {'kind': 'rename', 'path': '/tmp/renamed.txt'},
        },
      );
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(guard.contexts.map((context) => context.toolName), ['file_write', 'file_edit', 'file_write']);
      expect(guard.contexts.take(2).map((context) => context.toolInput?['file_path']), [
        '/tmp/new.txt',
        '/tmp/existing.txt',
      ]);
      expect(guard.contexts.map((context) => context.rawProviderToolName), [
        'file_change',
        'file_change',
        'file_change',
      ]);
      expect(
        fake.sentMessages
            .where((message) => message['id'].toString().startsWith('file-'))
            .map((message) => message['result']),
        everyElement({'approved': true}),
      );
    });

    test('warns and falls back to codex-prefixed tool names for unmapped approvals', () async {
      final fake = FakeCodexProcess();
      final guard = _RecordingGuard();
      final records = <LogRecord>[];
      final oldLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = oldLevel;
        await sub.cancel();
      });

      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-unmapped',
        messages: [
          {'role': 'user', 'content': 'run unknown tool'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'allow-unmapped',
        toolUseId: 'tool-unmapped',
        toolName: 'todo_list',
        extraParams: {
          'tool_input': {
            'items': ['a', 'b'],
          },
        },
      );
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(guard.contexts, hasLength(1));
      expect(guard.contexts.single.toolName, 'codex:todo_list');
      expect(guard.contexts.single.rawProviderToolName, 'todo_list');
      expect(
        records.any(
          (record) =>
              record.loggerName == 'CodexHarness' &&
              record.level == Level.WARNING &&
              record.message.contains('Falling back to unmapped Codex tool name: todo_list -> codex:todo_list'),
        ),
        isTrue,
      );
      final allowResponse = fake.sentMessages.singleWhere((message) => message['id'] == 'allow-unmapped');
      expect(allowResponse['result'], {'approved': true});
    });

    test('Codex file_change approvals hit FileGuard protected-path rules', () async {
      final fake = FakeCodexProcess();
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(
          guards: [
            FileGuard(
              config: FileGuardConfig(
                rules: const [FileGuardRule(pattern: '**/.env', level: FileAccessLevel.readOnly)],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-file-guard',
        messages: [
          {'role': 'user', 'content': 'update secret file'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'deny-file-guard',
        toolUseId: 'tool-file-guard',
        toolName: 'file_change',
        extraParams: {
          'tool_input': {
            'changes': [
              {'kind': 'update', 'path': '/tmp/project/notes.txt', 'old_text': 'A=1', 'new_text': 'A=2'},
              {'kind': 'update', 'path': '/tmp/project/.env', 'old_text': 'A=1', 'new_text': 'A=2'},
            ],
          },
        },
      );
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      final denial = fake.sentMessages.singleWhere((message) => message['id'] == 'deny-file-guard');
      expect((denial['result'] as Map<String, dynamic>)['approved'], isFalse);
      expect(
        (denial['result'] as Map<String, dynamic>)['reason'],
        contains('File access blocked: read_only (write) on /tmp/project/.env'),
      );
    });

    test('redacts env before guard evaluation and fails closed on approval-path errors', () async {
      final fake = FakeCodexProcess();
      final redactingGuard = _RecordingGuard();
      final records = <LogRecord>[];
      final oldLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = oldLevel;
        await sub.cancel();
      });

      final harness = _buildHarness(
        process: fake,
        environment: const {'OPENAI_API_KEY': 'sk-test-key'},
        guardChain: GuardChain(guards: [redactingGuard, _ThrowingGuard()]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-fail-closed',
        messages: [
          {'role': 'user', 'content': 'run with env'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'deny-error',
        toolUseId: 'tool-error',
        toolName: 'command_execution',
        extraParams: {
          'tool_input': {
            'command': 'printenv',
            'env': {'OPENAI_API_KEY': 'sk-test-key', 'CODEX_API_KEY': 'sk-test-key', 'SAFE': '1'},
          },
        },
      );
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(redactingGuard.contexts, hasLength(1));
      expect(redactingGuard.contexts.single.toolInput?['env'], {'SAFE': '1'});
      final denial = fake.sentMessages.singleWhere((message) => message['id'] == 'deny-error');
      expect(denial['result'], isA<Map<String, dynamic>>());
      final denialResult = denial['result'] as Map<String, dynamic>;
      expect(denialResult['approved'], isFalse);
      expect(denialResult['reason'], 'Guard error: Bad state: guard exploded');
      expect(
        records.any(
          (record) =>
              record.loggerName == 'GuardChain' &&
              record.level == Level.SEVERE &&
              record.message.contains('Guard throwing-guard threw: Bad state: guard exploded'),
        ),
        isTrue,
      );

      final fakeAllow = FakeCodexProcess();
      final allowHarness = _buildHarness(
        process: fakeAllow,
        environment: const {'OPENAI_API_KEY': 'sk-test-key'},
        guardChain: GuardChain(guards: [_RecordingGuard()]),
      );
      addTearDown(() async => allowHarness.dispose());
      await startHarness(allowHarness, fakeAllow);

      final allowTurnFuture = allowHarness.turn(
        sessionId: 'sess-strip',
        messages: [
          {'role': 'user', 'content': 'run with env'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fakeAllow);
      fakeAllow.emitApprovalRequest(
        requestId: 'allow-strip',
        toolUseId: 'tool-strip',
        toolName: 'command_execution',
        extraParams: {
          'tool_input': {
            'command': 'printenv',
            'env': {'OPENAI_API_KEY': 'sk-test-key', 'CODEX_API_KEY': 'sk-test-key', 'SAFE': '1'},
          },
        },
      );
      fakeAllow.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await allowTurnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(
        records.any(
          (record) =>
              record.loggerName == 'CodexHarness' &&
              record.level == Level.INFO &&
              record.message.contains('Stripped Codex API key environment variables from approval input env'),
        ),
        isTrue,
      );
      final allowResponse = fakeAllow.sentMessages.singleWhere((message) => message['id'] == 'allow-strip');
      expect(jsonEncode(allowResponse).contains('OPENAI_API_KEY'), isFalse);
      expect(jsonEncode(allowResponse).contains('CODEX_API_KEY'), isFalse);
    });
  });
}
