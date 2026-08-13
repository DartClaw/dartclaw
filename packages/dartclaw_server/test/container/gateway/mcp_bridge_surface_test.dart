import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

import 'gateway_test_support.dart';

const _canonicals = {
  'brave_search': CanonicalTool.webSearch,
  'web_fetch': CanonicalTool.webFetch,
  'sessions_spawn': CanonicalTool.sessionsSpawn,
  'memory_apply': CanonicalTool.memoryApply,
  'memory_observe': CanonicalTool.memoryObserve,
};

const _toolResponse = {
  'content': [
    {'type': 'text', 'text': 'ok'},
  ],
};

void main() {
  late McpProtocolHandler registry;
  late List<String> called;

  setUp(() {
    called = [];
    registry = McpProtocolHandler()
      ..registerTool(RecordingMcpTool('brave_search', called))
      ..registerTool(RecordingMcpTool('web_fetch', called))
      ..registerTool(RecordingMcpTool('sessions_spawn', called))
      ..registerTool(RecordingMcpTool('kg_add', called));
  });

  group('bridged MCP discovery', () {
    test('exposes nothing to an authority with no configured allowlist', () async {
      final surface = _surface(registry, const {});

      expect(await _listTools(surface), isEmpty);
    });

    test('exposes only the implementations behind an allowed canonical name', () async {
      final surface = _surface(registry, {'web_search'});

      expect(await _listTools(surface), ['brave_search']);
    });

    test('resolves several canonical names at once', () async {
      final surface = _surface(registry, {'web_search', 'web_fetch'});

      expect(await _listTools(surface), containsAll(['brave_search', 'web_fetch']));
      expect(await _listTools(surface), isNot(contains('sessions_spawn')));
    });

    test('never exposes a tool that has no explicit canonical mapping', () async {
      // `mcp_call` is the canonical for every unmapped tool at once, so
      // honouring it would turn one allowlist entry into a registry-wide
      // wildcard covering outbound third-party MCP adapters.
      expect(await _listTools(_surface(registry, {'web_search'})), isNot(contains('kg_add')));
      expect(await _listTools(_surface(registry, {'mcp_call'})), isEmpty);
      expect((await _call(_surface(registry, {'mcp_call'}), 'kg_add'))['error'], isNotNull);
    });
  });

  group('bridged MCP authorization', () {
    test('dispatches an authorized call to the host implementation', () async {
      final surface = _surface(registry, {'web_search'});

      final response = await _call(surface, 'brave_search');

      expect(response['result'], isNotNull);
      expect(called, ['brave_search']);
    });

    test('denies an unapproved tool before it reaches the implementation', () async {
      final denials = <String>[];
      final surface = _surface(registry, {'web_search'}, onDenied: denials.add);

      // The client calls directly rather than relying on the filtered listing:
      // client-side suppression is not the enforcement point.
      final response = await _call(surface, 'sessions_spawn');

      expect(response['error'], isNotNull);
      expect(called, isEmpty);
      expect(denials, ['sessions_spawn']);
    });

    test('denies every tool when the authority has no allowlist', () async {
      final surface = _surface(registry, const {});

      expect((await _call(surface, 'brave_search'))['error'], isNotNull);
      expect(called, isEmpty);
    });

    test('answers a denied and an unregistered tool with the same shape', () async {
      final surface = _surface(registry, {'web_search'});

      final denied = (await _call(surface, 'sessions_spawn'))['error'] as Map<String, Object?>;
      final unknown = (await _call(surface, 'no_such_tool'))['error'] as Map<String, Object?>;

      // A scoped caller must not be able to tell "exists but denied" from
      // "does not exist" — only the echoed name differs.
      expect(denied['code'], unknown['code']);
      expect(denied['message'], 'Tool not available: sessions_spawn');
      expect(unknown['message'], 'Tool not available: no_such_tool');
    });

    test('two authorities on the same registry get their own policy', () async {
      final searcher = _surface(registry, {'web_search'});
      final fetcher = _surface(registry, {'web_fetch'});

      expect((await _call(searcher, 'brave_search'))['result'], isNotNull);
      expect((await _call(fetcher, 'brave_search'))['error'], isNotNull);
      expect((await _call(fetcher, 'web_fetch'))['result'], isNotNull);
      expect(called, ['brave_search', 'web_fetch']);
    });

    test('refuses a non-POST request', () async {
      final surface = _surface(registry, {'web_search'});

      await expectLater(
        surface.handle(_request(method: 'GET', body: '')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 405)),
      );
    });

    test('refuses a body beyond the bridged request cap', () async {
      final surface = _surface(registry, {'web_search'}, maxRequestBytes: 32);

      await expectLater(
        surface.handle(_request(body: 'x' * 128)),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 413)),
      );
    });
  });

  group('bridged memory provenance', () {
    test('memory writes receive only principal-derived session, task, and agent identity', () async {
      final contexts = <String, MemoryCaptureContext>{};
      final registry = McpProtocolHandler()
        ..registerTool(
          MemoryApplyTool(
            handler: (_) async => _toolResponse,
            contextualHandler: (args, context) async {
              contexts['apply'] = context;
              return _toolResponse;
            },
          ),
        )
        ..registerTool(
          MemoryObserveTool(
            handler: (_) async => _toolResponse,
            contextualHandler: (args, context) async {
              contexts['observe'] = context;
              return _toolResponse;
            },
          ),
        );
      final surface = _surface(registry, {
        'memory_apply',
        'memory_observe',
      }, caller: principal(sessionId: 'session-42', taskId: 'task-42', logicalAgentId: 'memory-agent'));

      expect(
        (await _call(
          surface,
          'memory_apply',
          arguments: {
            'expectedRevision': 1,
            'operations': [
              {'kind': 'add', 'correlationId': 'c1', 'topic': 'preferences', 'content': 'Use metric units'},
            ],
          },
        ))['result'],
        isNotNull,
      );
      expect(
        (await _call(
          surface,
          'memory_observe',
          arguments: {'text': 'Prefers metric units', 'role': 'observation'},
        ))['result'],
        isNotNull,
      );

      for (final context in contexts.values) {
        expect(context.originKind?.name, 'turn');
        expect(context.sourceLocator, 'task:task-42');
        expect(context.sourceEvent, startsWith('mcp-call:'));
        expect(context.caller, 'memory-agent');
        expect(context.sessionRef, 'session-42');
      }
      expect(contexts.keys, unorderedEquals(['apply', 'observe']));
      expect(contexts['apply']!.sourceEvent, isNot(contexts['observe']!.sourceEvent));
    });

    test('primary, logical-agent, and task calls record only identity the host really owns', () async {
      final contexts = <MemoryCaptureContext>[];
      final registry = McpProtocolHandler()
        ..registerTool(
          MemoryObserveTool(
            handler: (_) async => _toolResponse,
            contextualHandler: (args, context) async {
              contexts.add(context);
              return _toolResponse;
            },
          ),
        );
      final cases = <({GatewayPrincipal principal, String locator, String caller, String? session})>[
        (
          principal: const GatewayPrincipal(
            sessionId: 'primary',
            providerId: 'claude',
            policy: ExecutionPolicy.container('workspace'),
          ),
          locator: 'authority:primary',
          caller: 'mcp-bridge:memory_observe',
          session: null,
        ),
        (
          principal: principal(sessionId: 'logical-session', logicalAgentId: 'researcher'),
          locator: 'session:logical-session',
          caller: 'researcher',
          session: 'logical-session',
        ),
        (
          principal: principal(sessionId: 'task-session', taskId: 'task-7'),
          locator: 'task:task-7',
          caller: 'mcp-bridge:memory_observe',
          session: 'task-session',
        ),
      ];

      for (final item in cases) {
        final surface = _surface(registry, {'memory_observe'}, caller: item.principal);
        await _call(surface, 'memory_observe', arguments: {'text': item.locator, 'role': 'observation'});
        final context = contexts.last;
        expect(context.sourceLocator, item.locator);
        expect(context.sourceEvent, startsWith('mcp-call:${item.principal.sessionId}:'));
        expect(context.caller, item.caller);
        expect(context.sessionRef, item.session);
      }

      expect(contexts.map((context) => context.sourceEvent).toSet(), hasLength(cases.length));
    });

    test('caller arguments cannot forge memory provenance', () async {
      var handlerCalls = 0;
      final registry = McpProtocolHandler()
        ..registerTool(
          MemoryObserveTool(
            handler: (_) async => _toolResponse,
            contextualHandler: (args, context) async {
              handlerCalls++;
              return _toolResponse;
            },
          ),
        );
      final surface = _surface(registry, {
        'memory_observe',
      }, caller: principal(sessionId: 'real-session', taskId: 'real-task', logicalAgentId: 'real-agent'));

      final response = await _call(
        surface,
        'memory_observe',
        arguments: {
          'text': 'Injected claim',
          'role': 'observation',
          'sessionId': 'forged-session',
          'taskId': 'forged-task',
          'agentId': 'forged-agent',
          'provenance': {'source': 'forged'},
        },
      );

      expect(response['error'], isNotNull);
      expect(handlerCalls, 0);
    });

    test('rejects a bridged memory call when its transport supplies no caller authority', () async {
      final registry = McpProtocolHandler()
        ..registerTool(
          MemoryObserveTool(
            handler: (_) async => _toolResponse,
            contextualHandler: (args, context) async => _toolResponse,
          ),
        );
      final surface = _surface(
        registry,
        {'memory_observe'},
        caller: const GatewayPrincipal(
          sessionId: ' ',
          providerId: 'claude',
          policy: ExecutionPolicy.container('workspace'),
        ),
      );
      final response = await _call(surface, 'memory_observe', arguments: {'text': 'no context', 'role': 'observation'});

      expect((response['result'] as Map<String, Object?>)['isError'], isTrue);
    });

    test('a failed authority call cannot leak its context into another authority', () async {
      final contexts = <MemoryCaptureContext>[];
      final registry = McpProtocolHandler()
        ..registerTool(
          MemoryObserveTool(
            handler: (_) async => _toolResponse,
            contextualHandler: (args, context) async {
              contexts.add(context);
              if (args['text'] == 'fail') throw StateError('expected failure');
              return _toolResponse;
            },
          ),
        );
      final first = _surface(registry, {
        'memory_observe',
      }, caller: principal(sessionId: 'first-session', taskId: 'first-task'));
      final second = _surface(registry, {
        'memory_observe',
      }, caller: principal(sessionId: 'second-session', taskId: 'second-task'));

      expect(
        (await _call(first, 'memory_observe', arguments: {'text': 'fail', 'role': 'observation'}))['result'],
        isNotNull,
      );
      await _call(second, 'memory_observe', arguments: {'text': 'succeed', 'role': 'observation'});

      expect(contexts, hasLength(2));
      expect(contexts.last.sourceLocator, 'task:second-task');
      expect(contexts.last.sourceEvent, startsWith('mcp-call:'));
      expect(contexts.last.sessionRef, 'second-session');
    });
  });
}

McpBridgeSurface _surface(
  McpProtocolHandler registry,
  Set<String> allowed, {
  void Function(String toolName)? onDenied,
  int maxRequestBytes = 1024 * 1024,
  GatewayPrincipal? caller,
}) => McpBridgeSurface(
  handler: registry,
  principal: caller ?? principal(logicalAgentId: 'search-agent'),
  allowedCanonicalTools: allowed,
  toolCanonicals: _canonicals,
  onDenied: onDenied == null ? null : (_, toolName) => onDenied(toolName),
  maxRequestBytes: maxRequestBytes,
);

GatewayRequest _request({String method = 'POST', required String body}) => GatewayRequest(
  principal: principal(),
  method: method,
  path: '/mcp',
  headers: const {},
  body: body.isEmpty ? const Stream<List<int>>.empty() : Stream.value(utf8.encode(body)),
);

Future<List<String>> _listTools(McpBridgeSurface surface) async {
  final response = await _exchange(surface, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
  final tools = (response['result'] as Map<String, Object?>)['tools'] as List<Object?>;
  return [for (final tool in tools) (tool as Map<String, Object?>)['name'] as String];
}

Future<Map<String, Object?>> _call(
  McpBridgeSurface surface,
  String toolName, {
  Map<String, Object?> arguments = const {},
}) => _exchange(surface, {
  'jsonrpc': '2.0',
  'id': 2,
  'method': 'tools/call',
  'params': {'name': toolName, 'arguments': arguments},
});

Future<Map<String, Object?>> _exchange(McpBridgeSurface surface, Map<String, Object?> request) async {
  final response = await surface.handle(_request(body: jsonEncode(request)));
  expect(response.status, 200);
  final body = utf8.decode((await response.body.toList()).expand((chunk) => chunk).toList());
  return jsonDecode(body) as Map<String, Object?>;
}
