import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/knowledge/wiki_page_store.dart';
import 'package:dartclaw_runtime/src/mcp/kg_tools.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/memory_tools.dart';
import 'package:dartclaw_runtime/src/mcp/wiki_write_tool.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTemporalKnowledgeGraphService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('temporary messages remain readable while durable projection and files stay empty', () async {
    final root = Directory.systemTemp.createTempSync('temporary-consumers-');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
    final workspace = AgentWorkspace.managed(
      agentId: 'temporary-agent',
      dataDir: root.path,
      ownerWorkspaceDir: '${root.path}/workspace',
    );
    final session = await sessions.createSession(retention: ConversationRetention.process, workspace: workspace);
    final message = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'consumer marker');
    expect((await messages.getMessages(session.id)).single.id, message.id);
    expect(SessionService.persistedPrincipal(session), 'agent:temporary-agent');
    expect(SessionService.isVisibleToPrincipal(session, 'owner'), isTrue);
    expect(SessionService.isVisibleToPrincipal(session, 'agent:peer'), isFalse);
    expect(
      ConversationIndexProjection.document(message: message, sessionType: session.type, retention: session.retention),
      isNull,
    );
    expect(root.listSync(recursive: true), isEmpty);
  });

  test('temporary identity outranks direct, malformed, alias, and explicit shared write attempts', () async {
    const marker = 'TEMPORARY_DURABLE_SINK_MARKER';
    final root = Directory.systemTemp.createTempSync('temporary-write-attempts-');
    addTearDown(() => root.deleteSync(recursive: true));
    final memoryFile = File(p.join(root.path, 'memory', 'capture.txt'));
    final kg = InMemoryTemporalKnowledgeGraphService();
    final handler = McpProtocolHandler();
    Future<ToolResult?> refuseTemporary(McpCallerContext context) async => context.sessionId == 'temporary-session'
        ? const ToolResult.error('Temporary conversations cannot write durable knowledge')
        : null;
    handler.registerTool(
      MemoryObserveTool(
        handler: (_) async => const {},
        callerHandler: (arguments, context) async {
          if (context.sessionId == 'temporary-session') {
            throw StateError('Temporary conversations cannot write memory');
          }
          memoryFile
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(arguments['text'] as String);
          return const {'status': 'captured'};
        },
      ),
    );
    handler.registerTool(
      WikiWriteTool(
        wiki: WikiPageStore(workspaceDir: root.path),
        contextualWriteGuard: refuseTemporary,
      ),
    );
    handler.registerTool(KgAddTool(kg: kg, contextualWriteGuard: refuseTemporary));
    final temporary = handler.scopedTo(
      _AllowEveryTool(),
      callerIdentity: const McpCallerIdentity(
        authorityId: 'temporary:temporary-session',
        sessionId: 'temporary-session',
        agentId: 'main',
      ),
    );

    final memory = await _call(temporary, 'memory_observe', {'text': marker, 'role': 'observation'});
    final wiki = await _call(temporary, 'wiki_write', {
      'slug': 'temporary-durable-sink-marker',
      'title': 'Temporary durable sink marker',
      'body': marker,
      'sources': ['temporary-conversation'],
    });
    final graph = await _call(temporary, 'kg_add', {
      'entity': marker,
      'predicate': 'status',
      'value': 'must-not-persist',
      'valid_from': '2026-09-22T00:00:00Z',
      'source': 'temporary-conversation',
    });
    final malformed = await _call(temporary, 'wiki_write', {'slug': 'temporary', 'body': marker});
    final alias = await _call(temporary, 'mcp__dartclaw__wiki_write', {'body': marker});
    final inbox = await _call(temporary, 'knowledge_inbox_ingest', {'text': marker});

    expect(memory, contains('Temporary conversations cannot write memory'));
    expect(wiki, contains('Temporary conversations cannot write durable knowledge'));
    expect(graph, contains('Temporary conversations cannot write durable knowledge'));
    expect(malformed, contains('Temporary conversations cannot write durable knowledge'));
    expect(alias, contains('Tool not available'));
    expect(inbox, contains('Tool not available'));
    expect(memoryFile.existsSync(), isFalse);
    expect(File(p.join(root.path, 'wiki', 'temporary-durable-sink-marker.md')).existsSync(), isFalse);
    expect(await kg.query(entity: marker), isEmpty);
  });
}

Future<String> _call(McpProtocolHandler handler, String name, Map<String, dynamic> arguments) async =>
    (await handler.handleRequest(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': arguments},
      }),
    ))!;

final class _AllowEveryTool implements McpCallerPolicy {
  @override
  bool allows(String toolName) => true;

  @override
  void onDenied(String toolName) {}
}
