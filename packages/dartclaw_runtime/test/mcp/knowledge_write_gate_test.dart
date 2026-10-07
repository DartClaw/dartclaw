import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/knowledge/wiki_page_store.dart';
import 'package:dartclaw_runtime/src/mcp/kg_tools.dart';
import 'package:dartclaw_runtime/src/mcp/knowledge_write_gate.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/wiki_write_tool.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTemporalKnowledgeGraphService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';
import 'mcp_test_support.dart' show AllowAllCallerPolicy;

const _admin = 'admin-a';
const _member = 'member-b';

void main() {
  late Directory workspace;
  late InMemoryTemporalKnowledgeGraphService kg;
  late RecordingGuardAuditLogger audit;
  late McpProtocolHandler base;
  late int seededFact;

  KnowledgeWriteGate gate({List<String> admins = const [_admin], GuardAuditLogger? logger}) => KnowledgeWriteGate(
    isAdmin: GovernanceConfig(adminSenders: admins).isAdmin,
    auditLogger: logger ?? audit,
    refuseFirst: (caller) async => caller.sessionId == 'temporary-session'
        ? const ToolResult.error('Temporary conversations cannot write durable knowledge')
        : null,
  );

  void registerTools(KnowledgeWriteGate gate) {
    base = McpProtocolHandler()
      ..registerTool(
        WikiWriteTool(
          wiki: WikiPageStore(workspaceDir: workspace.path),
          contextualWriteGuard: gate.guardFor('wiki_write'),
        ),
      )
      ..registerTool(KgAddTool(kg: kg, contextualWriteGuard: gate.guardFor('kg_add')))
      ..registerTool(KgInvalidateTool(kg: kg, contextualWriteGuard: gate.guardFor('kg_invalidate')));
  }

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('knowledge_write_gate_');
    kg = InMemoryTemporalKnowledgeGraphService();
    audit = RecordingGuardAuditLogger();
    seededFact = await kg.addFact(
      entity: 'seeded',
      predicate: 'status',
      value: 'open',
      validFrom: '2026-01-01T00:00:00Z',
      source: 'seed',
    );
    registerTools(gate());
  });

  tearDown(() => workspace.deleteSync(recursive: true));

  TurnProvenance channelTurn(ChannelType type, String? sender) =>
      TurnProvenance.channel(channelType: type, sessionKey: 'agent:main:group:${type.name}:g1', senderId: sender);

  McpProtocolHandler during(TurnProvenance? turn) => base.forHarness(() => turn);

  Map<String, dynamic> kgAdd(String entity) => {
    'entity': entity,
    'predicate': 'status',
    'value': 'recorded',
    'valid_from': '2026-10-06T00:00:00Z',
    'source': 'gate-test',
  };
  Map<String, dynamic> wikiWrite(String slug) => {
    'slug': slug,
    'title': 'Gate Test',
    'body': 'Written during a turn.',
    'sources': ['gate-test'],
  };
  Map<String, dynamic> kgInvalidate() => {
    'id': seededFact,
    'invalidated_at': '2026-10-06T00:00:00Z',
    'reason': 'gate-test',
  };
  File wikiFile(String slug) => File(p.join(workspace.path, 'wiki', '$slug.md'));
  Future<bool> addedFact(String entity) async => (await kg.query(entity: entity)).isNotEmpty;
  Future<bool> seededFactInvalidated() async => (await kg.factById(seededFact))!.invalidatedAt != null;
  List<AuditEntry> gateEntries() => audit.entries.where((entry) => entry.guard == 'KnowledgeWriteGate').toList();

  group('a channel turn by a non-admin sender', () {
    test('cannot write the wiki or the graph on every channel type, and nothing changes', () async {
      for (final type in [ChannelType.whatsapp, ChannelType.googlechat]) {
        final handler = during(channelTurn(type, _member));

        final wiki = await _call(handler, 'wiki_write', wikiWrite('denied-${type.name}'));
        final add = await _call(handler, 'kg_add', kgAdd('denied ${type.name}'));
        final invalidate = await _call(handler, 'kg_invalidate', kgInvalidate());

        for (final refusal in [wiki, add, invalidate]) {
          expect(refusal, allOf(contains('"isError":true'), contains('admin_senders')), reason: type.name);
        }
        expect(wikiFile('denied-${type.name}').existsSync(), isFalse);
        expect(await addedFact('denied ${type.name}'), isFalse);
        expect(await seededFactInvalidated(), isFalse);
      }
    });

    test('is audited once per call with tool, channel and sender', () async {
      for (final type in [ChannelType.whatsapp, ChannelType.googlechat]) {
        final handler = during(channelTurn(type, _member));
        await _call(handler, 'wiki_write', wikiWrite('denied-${type.name}'));
        await _call(handler, 'kg_add', kgAdd('denied ${type.name}'));
        await _call(handler, 'kg_invalidate', kgInvalidate());
      }

      final entries = gateEntries();
      expect(entries, hasLength(6));
      for (final entry in entries) {
        expect(entry.decision, 'deny');
        expect(entry.verdict, 'block');
        expect(entry.hook, 'mcp_tool_call');
        expect(entry.peerId, _member);
        expect(entry.principal, _member);
      }
      expect(
        {for (final entry in entries) (entry.tool, entry.channel)},
        {
          for (final tool in ['wiki_write', 'kg_add', 'kg_invalidate'])
            for (final channel in ['whatsapp', 'googlechat']) (tool, channel),
        },
      );
    });

    test('is refused when the channel turn names no sender, rather than read as unattributed', () async {
      final handler = during(channelTurn(ChannelType.whatsapp, null));

      expect(await _call(handler, 'kg_add', kgAdd('no sender')), contains('admin_senders'));

      expect(await addedFact('no sender'), isFalse);
      expect(gateEntries().single.reason, 'channel turn carries no sender');
      expect(gateEntries().single.peerId, isNull);
    });
  });

  group('a channel turn by an admin sender', () {
    test('writes the wiki and the graph, each call audited as allowed with channel and sender', () async {
      final handler = during(channelTurn(ChannelType.whatsapp, _admin));

      final wiki = await _call(handler, 'wiki_write', wikiWrite('admin-page'));
      final add = await _call(handler, 'kg_add', kgAdd('admin fact'));
      final invalidate = await _call(handler, 'kg_invalidate', kgInvalidate());

      expect(wiki, contains('created'));
      expect(add, contains('added'));
      expect(invalidate, contains('invalidated'));
      expect(wikiFile('admin-page').existsSync(), isTrue);
      expect(await addedFact('admin fact'), isTrue);
      expect(await seededFactInvalidated(), isTrue);
      expect(
        {for (final entry in gateEntries()) (entry.tool, entry.decision, entry.channel, entry.peerId)},
        {
          ('wiki_write', 'allow', 'whatsapp', _admin),
          ('kg_add', 'allow', 'whatsapp', _admin),
          ('kg_invalidate', 'allow', 'whatsapp', _admin),
        },
      );
    });

    test('with no admin_senders configured every sender is an admin and is still audited', () async {
      registerTools(gate(admins: const []));

      final add = await _call(during(channelTurn(ChannelType.signal, _member)), 'kg_add', kgAdd('open governance'));

      expect(add, contains('added'));
      expect(await addedFact('open governance'), isTrue);
      expect(gateEntries().single.decision, 'allow');
      expect(gateEntries().single.peerId, _member);
    });

    test('an audit failure refuses the write rather than letting it through unrecorded', () async {
      registerTools(gate(logger: _FailingAuditLogger()));

      final add = await _call(during(channelTurn(ChannelType.whatsapp, _admin)), 'kg_add', kgAdd('unaudited'));

      expect(add, contains('audit failure'));
      expect(await addedFact('unaudited'), isFalse);
    });
  });

  group('every other caller', () {
    test(
      'web chat, a scheduled turn, a turn-less harness and the gateway token write as before, unaudited by the gate',
      () async {
        final callers = <String, McpProtocolHandler>{
          'web chat': during(const TurnProvenance.web(sessionKey: 'agent:main:web:')),
          'scheduled turn': during(const TurnProvenance.cron()),
          'no turn': during(null),
          'gateway token': base,
        };

        for (final entry in callers.entries) {
          final name = 'caller ${entry.key}';
          expect(await _call(entry.value, 'kg_add', kgAdd(name)), contains('added'), reason: entry.key);
          expect(await _call(entry.value, 'wiki_write', wikiWrite(name.replaceAll(' ', '-'))), contains('created'));
          expect(await addedFact(name), isTrue, reason: entry.key);
        }
        expect(gateEntries(), isEmpty);
      },
    );

    test('a temporary conversation is refused with its own message first, even for an admin channel turn', () async {
      final temporary = base.scopedTo(
        AllowAllCallerPolicy(),
        callerIdentity: const McpCallerIdentity(
          authorityId: 'temporary:temporary-session',
          sessionId: 'temporary-session',
          agentId: 'main',
        ),
        activeTurn: () => channelTurn(ChannelType.whatsapp, _admin),
      );

      final add = await _call(temporary, 'kg_add', kgAdd('temporary'));

      expect(add, contains('Temporary conversations cannot write durable knowledge'));
      expect(await addedFact('temporary'), isFalse);
      expect(gateEntries(), isEmpty);
    });

    test('the sender comes from the host turn alone, never from tool arguments', () async {
      final handler = during(channelTurn(ChannelType.whatsapp, _member));

      final add = await _call(handler, 'kg_add', {...kgAdd('forged'), 'sender': _admin});

      expect(add, anyOf(contains('admin_senders'), contains('additionalProperties'), contains('Invalid params')));
      expect(await addedFact('forged'), isFalse);
    });
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

final class _FailingAuditLogger extends GuardAuditLogger {
  @override
  Future<void> writeEntry(AuditEntry entry) async => throw StateError('audit sink offline');
}
