import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/api/sse_broadcast.dart';
import 'package:dartclaw_runtime/src/mcp/attach_media_tool.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/scheduling/delivery.dart';
import 'package:dartclaw_runtime/src/workspace/workspace_path_guard.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, FakeGuard, InMemorySessionService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

void main() {
  const peerId = 'dm/contact/owner@s.whatsapp.net';
  const secondPeerId = 'dm/contact/owner-tablet@s.whatsapp.net';

  late Directory tempRoot;
  late Directory workspace;
  late Directory outside;
  late String resolvedReport;
  late String outsideFile;
  late InMemorySessionService sessions;
  late SseBroadcast sseBroadcast;
  late FakeChannel whatsapp;
  late ChannelManager channels;
  late DeliveryService delivery;
  late RecordingGuardAuditLogger audit;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('attach_media_tool_');
    workspace = Directory(p.join(tempRoot.path, 'workspace'))..createSync();
    outside = Directory(p.join(tempRoot.path, 'outside'))..createSync();

    Directory(p.join(workspace.path, 'reports')).createSync();
    File(p.join(workspace.path, 'reports', 'q3.pdf')).writeAsStringSync('quarterly report');
    File(p.join(tempRoot.path, 'secrets.env')).writeAsStringSync('TOKEN=shh');
    outsideFile = p.join(outside.path, 'vault.env');
    File(outsideFile).writeAsStringSync('VAULT=shh');
    // A real link, not a synthesized path: a string-only containment check
    // would send this file.
    Link(p.join(workspace.path, 'link.pdf')).createSync(outsideFile);
    resolvedReport = p.join(workspace.resolveSymbolicLinksSync(), 'reports', 'q3.pdf');

    sessions = InMemorySessionService();
    sseBroadcast = SseBroadcast();
    whatsapp = FakeChannel(type: ChannelType.whatsapp, ownedJids: {peerId, secondPeerId});
    channels = ChannelManager(
      queue: MessageQueue(dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async => 'ok'),
      config: const ChannelConfig.defaults(),
    )..registerChannel(whatsapp);
    delivery = DeliveryService(channelManager: channels, sseBroadcast: sseBroadcast, sessions: sessions);
    audit = RecordingGuardAuditLogger();
  });

  tearDown(() async {
    await channels.dispose();
    await sseBroadcast.dispose();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Future<void> activateDmSession(String peer) async {
    await sessions.getOrCreateByKey(
      SessionKey.dmPerChannelContact(channelType: ChannelType.whatsapp.name, peerId: peer),
      type: SessionType.channel,
    );
  }

  /// Registers the real tool on the real dispatch seam.
  ///
  /// Guard evaluation and audit come from [McpProtocolHandler]; nothing in the
  /// tool participates, which is what the negative control proves.
  McpProtocolHandler handlerWith({GuardChain? chain, GuardAuditLogger? sink}) =>
      McpProtocolHandler(guardChain: chain, auditLogger: sink)
        ..registerTool(AttachMediaTool(workspace: WorkspacePathGuard(workspace.path), delivery: delivery));

  McpProtocolHandler passingHandler() => handlerWith(
    chain: GuardChain(guards: [FakeGuard.pass()]),
    sink: audit,
  );

  group('S07 attach_media delivers a contained workspace file to the owner\'s DM sessions', () {
    test('the file reaches the single DM target once, as the caption plus the resolved path', () async {
      await activateDmSession(peerId);

      final result = _result(
        await _call(passingHandler(), 'attach_media', arguments: {'path': 'reports/q3.pdf', 'caption': 'Q3'}),
      );

      expect(whatsapp.sentMessages, hasLength(1));
      expect(whatsapp.sentMessages.single.$1, peerId);
      expect(whatsapp.sentMessages.single.$2.text, 'Q3');
      expect(whatsapp.sentMessages.single.$2.mediaAttachments, [
        resolvedReport,
      ], reason: 'the channel must receive the resolved path, not the model-supplied one');

      expect(result['isError'], isNull);
      expect(_payload(result)['path'], 'reports/q3.pdf');
      expect(_payload(result)['delivered_to'], ['whatsapp:$peerId']);
    });

    test('two active DM sessions each receive the file exactly once', () async {
      await activateDmSession(peerId);
      await activateDmSession(secondPeerId);

      final result = _result(
        await _call(passingHandler(), 'attach_media', arguments: {'path': 'reports/q3.pdf', 'caption': 'Q3'}),
      );

      expect(whatsapp.sentMessages, hasLength(2));
      expect(whatsapp.sentMessages.map((sent) => sent.$1).toSet(), {peerId, secondPeerId});
      expect(whatsapp.sentMessages.map((sent) => sent.$2.mediaAttachments).toList(), [
        [resolvedReport],
        [resolvedReport],
      ]);
      expect((_payload(result)['delivered_to'] as List).toSet(), {'whatsapp:$peerId', 'whatsapp:$secondPeerId'});
    });

    test(
      'a reachable owner whose every send fails is reported as a delivery failure, not an absent recipient',
      () async {
        await activateDmSession(peerId);
        whatsapp.throwOnSend = true;

        final result = _result(
          await _call(passingHandler(), 'attach_media', arguments: {'path': 'reports/q3.pdf', 'caption': 'Q3'}),
        );

        expect(result['isError'], isTrue);
        // Collapsing this into no_recipient would tell the owner their session is
        // gone when the file simply did not send.
        expect(_payload(result)['reason'], 'delivery_failed');
        expect(_payload(result)['attempted'], 1);
      },
    );

    test('a call with no active DM session is a tool error, not a silent success', () async {
      final result = _result(
        await _call(passingHandler(), 'attach_media', arguments: {'path': 'reports/q3.pdf', 'caption': 'Q3'}),
      );

      expect(result['isError'], isTrue);
      expect(_payload(result)['reason'], 'no_recipient');
      expect(whatsapp.sentMessages, isEmpty);
    });
  });

  group('S07 every path that escapes the workspace is refused with no send attempted', () {
    // A DM target is active for each row, so a refusal here is containment's
    // work and not an absent recipient.
    setUp(() => activateDmSession(peerId));

    test('a traversal path, an absolute outside path and an in-workspace symlink out are each refused', () async {
      final handler = passingHandler();

      final escapes = ['../secrets.env', outsideFile, 'link.pdf'];
      for (final escape in escapes) {
        final result = _result(await _call(handler, 'attach_media', arguments: {'path': escape}));

        expect(result['isError'], isTrue, reason: '$escape must refuse as a tool error, not a protocol error');
        expect(_payload(result)['reason'], 'containment_refused');
        expect(
          _payload(result)['message'],
          '"$escape" is not inside the workspace and cannot be sent',
          reason: 'the refusal names containment, so the model can tell it from a missing file',
        );
        expect(_payload(result)['path'], escape);
      }

      expect(whatsapp.sentMessages, isEmpty, reason: 'no escape attempt may reach a channel');
    });
  });

  group('S07 negative control: a guard block refuses the tool with no side effect', () {
    test('the dispatch is refused, nothing is sent, and one deny entry names the tool', () async {
      await activateDmSession(peerId);
      final handler = handlerWith(
        chain: GuardChain(guards: [FakeGuard.block('attach_media disabled')]),
        sink: audit,
      );

      final result = _result(
        await _call(handler, 'attach_media', arguments: {'path': 'reports/q3.pdf', 'caption': 'Q3'}),
      );

      expect(result['isError'], isTrue);
      expect(_text(result), 'attach_media disabled');
      expect(whatsapp.sentMessages, isEmpty, reason: 'a blocked dispatch never runs the tool');
      expect(audit.entries.map((entry) => (entry.tool, entry.decision, entry.verdict)), [
        ('attach_media', 'deny', 'block'),
      ]);
    });
  });

  group('the declared argument contract is enforced before anything is sent', () {
    const cases = <({String label, Map<String, dynamic> arguments, String message})>[
      (label: 'a missing path', arguments: {'caption': 'Q3'}, message: 'path is required'),
      (label: 'a blank path', arguments: {'path': '  '}, message: 'path must be a non-empty string'),
    ];

    for (final testCase in cases) {
      test('${testCase.label} is refused as an invalid request', () async {
        await activateDmSession(peerId);

        final result = _result(await _call(passingHandler(), 'attach_media', arguments: testCase.arguments));

        expect(result['isError'], isTrue);
        expect(_payload(result)['reason'], 'invalid_request');
        expect(_payload(result)['message'], testCase.message);
        expect(whatsapp.sentMessages, isEmpty);
      });
    }
  });
}
