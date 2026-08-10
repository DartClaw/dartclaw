import 'dart:convert';

import 'package:dartclaw_core/src/harness/canonical_tool.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_core/src/harness/codex_protocol_adapter.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

CodexHarness _buildHarness({
  required FakeCodexProcess process,
  GuardChain? guardChain,
  Map<String, String>? environment,
  Map<String, CanonicalTool> ownMcpToolCanonicals = const {},
}) {
  return CodexHarness(
    cwd: '/tmp',
    executable: 'codex',
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
    commandProbe: defaultCommandProbe,
    delayFactory: noOpDelay,
    environment: environment ?? const {'OPENAI_API_KEY': 'sk-test-key'},
    guardChain: guardChain,
    adapter: CodexProtocolAdapter(ownMcpToolCanonicals: ownMcpToolCanonicals),
  );
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

class _DenyFileEditGuard extends Guard {
  final List<GuardContext> contexts = [];

  @override
  String get name => 'deny-file-edit';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    contexts.add(context);
    return context.toolName == 'file_edit' ? GuardVerdict.block('file edits denied') : GuardVerdict.pass();
  }
}

void main() {
  group('CodexHarness approval flow', () {
    test('routes current Codex approval methods through GuardChain', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final guard = RecordingGuard();
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
        ownMcpToolCanonicals: const {'memory_save': CanonicalTool.memorySave},
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-current-approvals',
        messages: [
          {'role': 'user', 'content': 'run guarded tools'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitLine({
        'id': 'command-current',
        'method': 'item/commandExecution/requestApproval',
        'params': {
          'threadId': 'thread-123',
          'turnId': 'turn-1',
          'itemId': 'command-1',
          'startedAtMs': 1,
          'command': 'git status',
          'cwd': '/tmp',
        },
      });
      fake.emitItemStarted('fileChange', 'file-1', {
        'changes': [
          {
            'kind': {'type': 'update'},
            'path': '/tmp/existing.txt',
          },
        ],
      });
      fake.emitLine({
        'id': 'file-current',
        'method': 'item/fileChange/requestApproval',
        'params': {'threadId': 'thread-123', 'turnId': 'turn-1', 'itemId': 'file-1', 'startedAtMs': 1},
      });
      fake.emitLine({
        'id': 'mcp-current',
        'method': 'mcpServer/elicitation/request',
        'params': {
          'threadId': 'thread-123',
          'turnId': 'turn-1',
          'serverName': 'dartclaw',
          'mode': 'form',
          '_meta': {
            'codex_approval_kind': 'mcp_tool_call',
            'tool_name': 'memory_save',
            'tool_params': {'content': 'fact'},
          },
          'message': 'Allow memory write?',
          'requestedSchema': {'type': 'object'},
        },
      });
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(guard.contexts.map((context) => context.toolName), ['shell', 'file_edit', 'memory_save']);
      expect(guard.contexts.map((context) => context.rawProviderToolName), [
        'command_execution',
        'file_change',
        'mcp_tool_call',
      ]);
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'command-current')['result'], {
        'decision': 'accept',
      });
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'file-current')['result'], {
        'decision': 'accept',
      });
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'mcp-current')['result'], {
        'action': 'accept',
        'content': null,
        '_meta': null,
      });
    });

    test('fails closed on unsupported current approval authority', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [FileGuard()]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-unsupported-authority',
        messages: [
          {'role': 'user', 'content': 'request broader authority'},
        ],
        systemPrompt: 'test',
      );
      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);

      final fileCases = <String, Map<String, dynamic>>{
        'delete': {
          'changes': [
            {
              'kind': {'type': 'delete'},
              'path': '/tmp/source.txt',
            },
          ],
        },
        'move': {
          'changes': [
            {
              'kind': {'type': 'update', 'move_path': '/tmp/destination.txt'},
              'path': '/tmp/source.txt',
            },
          ],
        },
        'grant-root': {
          'changes': [
            {
              'kind': {'type': 'add'},
              'path': '/tmp/new.txt',
            },
          ],
        },
      };
      for (final entry in fileCases.entries) {
        final itemId = 'file-${entry.key}';
        fake.emitItemStarted('fileChange', itemId, entry.value);
        fake.emitLine({
          'id': entry.key,
          'method': 'item/fileChange/requestApproval',
          'params': {
            'threadId': 'thread-123',
            'turnId': 'turn-1',
            'itemId': itemId,
            'startedAtMs': 1,
            if (entry.key == 'grant-root') 'grantRoot': '/tmp',
          },
        });
      }

      final commandCases = <String, ({Map<String, dynamic> params, String responseKey, Object response})>{
        'missing-command': (params: <String, dynamic>{}, responseKey: 'result', response: {'decision': 'decline'}),
        'extra-permission': (
          params: {
            'command': 'pwd',
            'additionalPermissions': {
              'network': {'enabled': true},
            },
          },
          responseKey: 'result',
          response: {'decision': 'decline'},
        ),
        'cancel-only': (
          params: {
            'command': 'pwd',
            'availableDecisions': ['cancel'],
          },
          responseKey: 'result',
          response: {'decision': 'cancel'},
        ),
        'accept-only-unsafe': (
          params: {
            'command': 'pwd',
            'additionalPermissions': {
              'network': {'enabled': true},
            },
            'availableDecisions': ['accept'],
          },
          responseKey: 'error',
          response: {'code': -32602, 'message': 'No safe approval decision was offered'},
        ),
      };
      for (final entry in commandCases.entries) {
        fake.emitLine({
          'id': entry.key,
          'method': 'item/commandExecution/requestApproval',
          'params': {
            'threadId': 'thread-123',
            'turnId': 'turn-1',
            'itemId': entry.key,
            'startedAtMs': 1,
            ...entry.value.params,
          },
        });
      }
      fake.emitLine({
        'id': 'request-user-input',
        'method': 'item/tool/requestUserInput',
        'params': <String, dynamic>{},
      });
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      for (final requestId in fileCases.keys) {
        expect(fake.sentMessages.singleWhere((message) => message['id'] == requestId)['result'], {
          'decision': 'decline',
        }, reason: requestId);
      }
      for (final entry in commandCases.entries) {
        expect(
          fake.sentMessages.singleWhere((message) => message['id'] == entry.key)[entry.value.responseKey],
          entry.value.response,
          reason: entry.key,
        );
      }
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'request-user-input')['error'], {
        'code': -32601,
        'message': 'Method not supported by DartClaw',
      });
    });

    test('routes approval requests through GuardChain and allows approved tools', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final guard = RecordingGuard();
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-allow',
        agentId: 'search',
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

      fake.emitApprovalRequest(
        requestId: 'after-turn',
        toolUseId: 'tool-after-turn',
        toolName: 'command_execution',
        extraParams: {
          'tool_input': {'command': 'git status'},
        },
      );
      await Future<void>.delayed(Duration.zero);

      expect(guard.contexts, hasLength(2));
      expect(guard.contexts.first.toolName, 'shell');
      expect(guard.contexts.first.rawProviderToolName, 'command_execution');
      expect(guard.contexts.first.sessionId, 'sess-allow');
      expect(guard.contexts.first.agentId, 'search');
      expect(guard.contexts.first.toolInput, {'command': 'git status'});
      expect(guard.contexts.last.sessionId, isNull);
      expect(guard.contexts.last.agentId, isNull);
      final allowResponse = fake.sentMessages.singleWhere((message) => message['id'] == 'allow-1');
      expect(allowResponse['jsonrpc'], '2.0');
      expect(allowResponse['result'], {'approved': true});
    });

    test('maps exact own-MCP approval identities and keeps unknown MCP calls generic', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final guard = RecordingGuard();
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
        ownMcpToolCanonicals: const {
          'web_fetch': CanonicalTool.webFetch,
          'brave_search': CanonicalTool.webSearch,
          'memory_save': CanonicalTool.memorySave,
        },
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-mcp-semantics',
        agentId: 'search',
        messages: [
          {'role': 'user', 'content': 'use MCP tools'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      final requests = [
        ('fetch', 'dartclaw', 'web_fetch', <String, dynamic>{'url': 'https://github.com'}),
        ('search', 'dartclaw', 'brave_search', <String, dynamic>{'query': 'Dart'}),
        ('memory', 'dartclaw', 'memory_save', <String, dynamic>{'content': 'fact'}),
        ('unknown-own', 'dartclaw', 'unknown', <String, dynamic>{}),
        ('third-party', 'github', 'search', <String, dynamic>{}),
      ];
      for (final (id, server, tool, arguments) in requests) {
        fake.emitApprovalRequest(
          requestId: id,
          toolUseId: 'tool-$id',
          toolName: 'mcp_tool_call',
          extraParams: {
            'tool_input': {'server': server, 'tool': tool, 'arguments': arguments},
          },
        );
      }
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(guard.contexts.map((context) => context.toolName), [
        'web_fetch',
        'web_search',
        'memory_save',
        'mcp_call',
        'mcp_call',
      ]);
      expect(guard.contexts.first.toolInput, {'url': 'https://github.com'});
      expect(guard.contexts.map((context) => context.rawProviderToolName), everyElement('mcp_tool_call'));
    });

    test('routes exact own-MCP web fetch approval arguments through NetworkGuard', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(
          guards: [
            NetworkGuard(
              config: NetworkGuardConfig(allowedDomains: const {'github.com'}, exfilPatterns: const []),
            ),
          ],
        ),
        ownMcpToolCanonicals: const {'web_fetch': CanonicalTool.webFetch},
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-mcp-fetch',
        messages: [
          {'role': 'user', 'content': 'fetch a page'},
        ],
        systemPrompt: 'test',
      );

      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'fetch-blocked',
        toolUseId: 'tool-fetch',
        toolName: 'mcp_tool_call',
        extraParams: {
          'tool_input': {
            'server': 'dartclaw',
            'tool': 'web_fetch',
            'arguments': {'url': 'https://example.com/page'},
          },
        },
      );
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      final response = fake.sentMessages.singleWhere((message) => message['id'] == 'fetch-blocked');
      expect(response['result'], {
        'approved': false,
        'reason': 'Network blocked: domain not in allowlist (example.com)',
      });
    });

    test('routes approval requests through GuardChain and denies blocked tools', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final guard = RecordingGuard(verdict: GuardVerdict.block('Blocked by test guard'));
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

    test('evaluates every exact file change and declines unknown kinds', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final guard = RecordingGuard();
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

      expect(guard.contexts.map((context) => context.toolName), ['file_write', 'file_edit']);
      expect(guard.contexts.take(2).map((context) => context.toolInput?['file_path']), [
        '/tmp/new.txt',
        '/tmp/existing.txt',
      ]);
      expect(guard.contexts.map((context) => context.rawProviderToolName), ['file_change', 'file_change']);
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'file-create')['result'], {'approved': true});
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'file-update')['result'], {'approved': true});
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'file-unknown')['result'], {
        'approved': false,
        'reason': 'File change context is incomplete',
      });
    });

    test('evaluates mixed file batches operation by operation and fails closed without context', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final guard = _DenyFileEditGuard();
      final harness = _buildHarness(
        process: fake,
        guardChain: GuardChain(guards: [guard]),
      );
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-file-batch',
        messages: [
          {'role': 'user', 'content': 'change files'},
        ],
        systemPrompt: 'test',
      );
      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitApprovalRequest(
        requestId: 'mixed-file',
        toolUseId: 'mixed-tool',
        toolName: 'file_change',
        extraParams: {
          'tool_input': {
            'changes': [
              {'kind': 'create', 'path': '/tmp/new.txt'},
              {'kind': 'update', 'path': '/tmp/existing.txt'},
            ],
          },
        },
      );
      fake.emitApprovalRequest(requestId: 'contextless-file', toolUseId: 'missing-tool', toolName: 'file_change');
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(guard.contexts.map((context) => context.toolName), ['file_write', 'file_edit']);
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'mixed-file')['result'], {
        'approved': false,
        'reason': 'file edits denied',
      });
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'contextless-file')['result'], {
        'approved': false,
        'reason': 'File change context is incomplete',
      });
    });

    test('responds immediately to unsupported permission and ordinary elicitation requests', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final harness = _buildHarness(process: fake);
      addTearDown(() async => harness.dispose());
      await startHarness(harness, fake);

      final turnFuture = harness.turn(
        sessionId: 'sess-unsupported-requests',
        messages: [
          {'role': 'user', 'content': 'request unsupported input'},
        ],
        systemPrompt: 'test',
      );
      await Future<void>.delayed(Duration.zero);
      await respondToLatestThreadStart(fake);
      fake.emitLine({
        'id': 'permission-request',
        'method': 'item/permissions/requestApproval',
        'params': {
          'threadId': 'thread-123',
          'turnId': 'turn-1',
          'itemId': 'permission-1',
          'startedAtMs': 1,
          'cwd': '/tmp',
          'permissions': <String, dynamic>{},
        },
      });
      fake.emitLine({
        'id': 'form-request',
        'method': 'mcpServer/elicitation/request',
        'params': {
          'threadId': 'thread-123',
          'turnId': 'turn-1',
          'serverName': 'forms',
          'mode': 'form',
          '_meta': {'source': 'form'},
          'message': 'Enter a value',
          'requestedSchema': {'type': 'object'},
        },
      });
      fake.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turnFuture;
      await Future<void>.delayed(Duration.zero);

      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'permission-request')['result'], {
        'permissions': <String, dynamic>{},
      });
      expect(fake.sentMessages.singleWhere((message) => message['id'] == 'form-request')['result'], {
        'action': 'decline',
        'content': null,
        '_meta': null,
      });
    });

    test('warns and falls back to codex-prefixed tool names for unmapped approvals', () async {
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final guard = RecordingGuard();
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
      final fake = FakeCodexProcess(completeExitOnKill: true);
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
      final fake = FakeCodexProcess(completeExitOnKill: true);
      final redactingGuard = RecordingGuard();
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

      final fakeAllow = FakeCodexProcess(completeExitOnKill: true);
      final allowHarness = _buildHarness(
        process: fakeAllow,
        environment: const {'OPENAI_API_KEY': 'sk-test-key'},
        guardChain: GuardChain(guards: [RecordingGuard()]),
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
