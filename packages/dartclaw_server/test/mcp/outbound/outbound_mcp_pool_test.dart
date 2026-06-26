import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart'
    show
        CredentialEntry,
        CredentialsConfig,
        McpNetworkClass,
        McpServerEntry,
        McpServerRateLimit,
        McpServerTokenBudget,
        McpServersConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, OutboundMcpGovernanceEvent;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_errors.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_models.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_pool.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_transport.dart';
import 'package:test/test.dart';

void main() {
  group('OutboundMcpPool', () {
    test('spawns, reuses, tears down after idle TTL, and respawns after unhealthy ping', () async {
      final timers = <_ManualTimer>[];
      final events = <OutboundMcpLifecycleEvent>[];
      final transports = <_PoolTransport>[];
      final pool = OutboundMcpPool(
        mcpServers: _registry({'stdio': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        idleTtl: const Duration(seconds: 5),
        timeout: const Duration(milliseconds: 50),
        transportFactory: (server, options) async {
          final transport = _PoolTransport();
          transports.add(transport);
          return transport;
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
        observer: events.add,
        timerFactory: (duration, callback) {
          final timer = _ManualTimer(callback);
          timers.add(timer);
          return timer;
        },
      );

      await pool.callTool(
        serverName: 'stdio',
        toolName: 'echo',
        arguments: {'text': 'first'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      await pool.callTool(
        serverName: 'stdio',
        toolName: 'echo',
        arguments: {'text': 'second'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      expect(transports, hasLength(1));
      expect(events.map((event) => event.type), containsAllInOrder(['spawn', 'reuse']));

      timers.last.fire();
      await Future<void>.delayed(Duration.zero);
      expect(transports.single.closed, isTrue);
      expect(events.map((event) => event.type), contains('idle-teardown'));

      await pool.callTool(
        serverName: 'stdio',
        toolName: 'echo',
        arguments: {'text': 'third'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      transports.last.healthy = false;
      await pool.callTool(
        serverName: 'stdio',
        toolName: 'echo',
        arguments: {'text': 'fourth'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      expect(transports, hasLength(3));
      expect(events.map((event) => event.type), containsAllInOrder(['respawn', 'spawn']));
    });

    test('unreachable server returns structured error and healthy server still succeeds', () async {
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'down': const McpServerEntry(command: 'down', networkClass: McpNetworkClass.local),
          'up': const McpServerEntry(command: 'up', networkClass: McpNetworkClass.local),
        }),
        timeout: const Duration(milliseconds: 50),
        transportFactory: (server, options) async {
          if (server.name == 'down') return _PoolTransport(failCalls: true);
          return _PoolTransport();
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );

      final down = await pool.callTool(
        serverName: 'down',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      final up = await pool.callTool(
        serverName: 'up',
        toolName: 'echo',
        arguments: {'text': 'ok'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(down.error!.code, 'timeout');
      expect(up.isSuccess, isTrue);
      expect(up.content.single['text'], 'ok');
    });

    test('failed list initialization closes the connection before later dispatch', () async {
      final transports = <_PoolTransport>[];
      final pool = OutboundMcpPool(
        mcpServers: _registry({'acme': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        timeout: const Duration(milliseconds: 50),
        transportFactory: (server, options) async {
          final transport = _PoolTransport(failToolsList: transports.isEmpty);
          transports.add(transport);
          return transport;
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );
      addTearDown(pool.close);

      await expectLater(pool.listTools('acme'), throwsA(isA<OutboundMcpException>()));
      final direct = await pool.callTool(
        serverName: 'acme',
        toolName: 'echo',
        arguments: {'text': 'ok'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(transports, hasLength(2));
      expect(transports.first.closed, isTrue);
      expect(direct.isSuccess, isTrue);
      expect(direct.content.single['text'], 'ok');
    });

    test('closed pool does not reconnect on list or call', () async {
      var factoryCalls = 0;
      final pool = OutboundMcpPool(
        mcpServers: _registry({'acme': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        transportFactory: (server, options) async {
          factoryCalls++;
          return _PoolTransport();
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );

      await pool.close();
      await expectLater(pool.listTools('acme'), throwsA(isA<OutboundMcpException>()));
      final direct = await pool.callTool(
        serverName: 'acme',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(direct.error!.code, 'pool_closed');
      expect(factoryCalls, 0);
    });

    test('close attempts every active connection before reporting a close failure', () async {
      final transports = <String, _PoolTransport>{};
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'first': const McpServerEntry(command: 'first', networkClass: McpNetworkClass.local),
          'second': const McpServerEntry(command: 'second', networkClass: McpNetworkClass.local),
        }),
        transportFactory: (server, options) async {
          final transport = _PoolTransport(failClose: server.name == 'first');
          transports[server.name] = transport;
          return transport;
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );

      await pool.listTools('first');
      await pool.listTools('second');
      await expectLater(pool.close(), throwsA(isA<StateError>()));

      expect(transports['first']!.closed, isTrue);
      expect(transports['second']!.closed, isTrue);
    });

    test('connection created during close is immediately closed and rejected', () async {
      final factoryStarted = Completer<void>();
      final releaseFactory = Completer<void>();
      late final _PoolTransport transport;
      final pool = OutboundMcpPool(
        mcpServers: _registry({'acme': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        transportFactory: (server, options) async {
          factoryStarted.complete();
          await releaseFactory.future;
          transport = _PoolTransport();
          return transport;
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );

      final listed = pool.listTools('acme');
      await factoryStarted.future;
      await pool.close();
      releaseFactory.complete();

      await expectLater(
        listed,
        throwsA(isA<OutboundMcpException>().having((error) => error.code, 'code', 'pool_closed')),
      );
      expect(transport.closed, isTrue);
    });

    test('operations that resume after close do not dispatch on a closed pool', () async {
      final transport = _PoolTransport();
      final pool = OutboundMcpPool(
        mcpServers: _registry({'acme': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        transportFactory: (server, options) async => transport,
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );

      await pool.listTools('acme');

      transport.blockPing();
      final listed = pool.listTools('acme');
      await transport.pingStarted;
      await pool.close();
      transport.releasePing(true);
      await expectLater(
        listed,
        throwsA(isA<OutboundMcpException>().having((error) => error.code, 'code', 'pool_closed')),
      );
      expect(transport.callCount, 0);

      final callTransport = _PoolTransport();
      final callPool = OutboundMcpPool(
        mcpServers: _registry({'acme': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        transportFactory: (server, options) async => callTransport,
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );
      await callPool.listTools('acme');

      callTransport.blockPing();
      final called = callPool.callTool(
        serverName: 'acme',
        toolName: 'echo',
        arguments: {'text': 'after-close'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      await callTransport.pingStarted;
      await callPool.close();
      callTransport.releasePing(true);

      final callResult = await called;
      expect(callResult.error!.code, 'pool_closed');
      expect(callTransport.callCount, 0);
    });

    test('absent or disabled registry entry is rejected without dispatch', () async {
      final tempDir = Directory.systemTemp.createTempSync('egress_unavailable_audit_test_');
      final auditLogger = GuardAuditLogger(dataDir: tempDir.path);
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      var dispatches = 0;
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'disabled': const McpServerEntry(command: 'fake', enabled: false, networkClass: McpNetworkClass.local),
        }),
        transportFactory: (server, options) async {
          dispatches++;
          return _PoolTransport();
        },
        guardDecisionHook: _allow,
        auditLogger: auditLogger,
      );

      final absent = await pool.callTool(
        serverName: 'missing',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      final disabled = await pool.callTool(
        serverName: 'disabled',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(absent.error!.code, 'egress_denied');
      expect(absent.decision, 'deny');
      expect(disabled.error!.code, 'egress_denied');
      expect(disabled.decision, 'deny');
      final entries = File(auditLogger.auditFilePath)
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry['decision']), everyElement('deny'));
      expect(entries.map((entry) => entry['server']), containsAll(['missing', 'disabled']));
      expect(dispatches, 0);
    });

    test('missing audit logger denies otherwise allowed egress', () async {
      var dispatches = 0;
      final pool = OutboundMcpPool(
        mcpServers: _registry({'linear': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        transportFactory: (server, options) async {
          dispatches++;
          return _PoolTransport();
        },
        guardDecisionHook: _allow,
      );

      final result = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 'session-1'),
      );

      expect(result.error!.code, 'egress_denied');
      expect(result.reason, contains('guard/audit failure'));
      expect(dispatches, 0);
    });

    test('rejecting guard prevents first-use transport creation', () async {
      var dispatches = 0;
      final pool = OutboundMcpPool(
        mcpServers: _registry({'stdio': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        guardHook: (_) async {
          throw const OutboundMcpException('egress_denied', 'blocked');
        },
        auditLogger: GuardAuditLogger(),
        transportFactory: (server, options) async {
          dispatches++;
          return _PoolTransport();
        },
      );

      final result = await pool.callTool(
        serverName: 'stdio',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1', principal: 'operator'),
      );

      expect(result.error!.code, 'egress_denied');
      expect(result.decision, 'deny');
      expect(dispatches, 0);
    });

    test('default-denies when no guard allowlist is configured', () async {
      var dispatches = 0;
      final pool = OutboundMcpPool(
        mcpServers: _registry({'stdio': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        transportFactory: (server, options) async {
          dispatches++;
          return _PoolTransport();
        },
        auditLogger: GuardAuditLogger(),
      );

      final result = await pool.callTool(
        serverName: 'stdio',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(result.error!.code, 'egress_denied');
      expect(result.decision, 'deny');
      expect(dispatches, 0);
    });

    test('guard decisions are audited exactly once with structured fields', () async {
      final tempDir = Directory.systemTemp.createTempSync('egress_audit_test_');
      final auditLogger = GuardAuditLogger(dataDir: tempDir.path);
      final guard = EgressGuard(
        allowlist: {
          'linear': ['list_issues'],
        },
      );
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': const McpServerEntry(
            command: 'fake',
            networkClass: McpNetworkClass.local,
            credential: 'linear-token',
          ),
        }),
        credentials: const CredentialsConfig(entries: {'linear-token': CredentialEntry(apiKey: 'secret-token')}),
        transportFactory: (server, options) async => _PoolTransport(),
        guardDecisionHook: (request) async {
          final verdict = await guard.evaluate(
            GuardContext(
              hookPoint: 'outboundMcpToolsCall',
              toolName: 'tools/call',
              toolInput: {'server': request.serverName, 'tool': request.toolName},
              sessionId: request.caller.sessionId,
              timestamp: DateTime.now().toUtc(),
            ),
          );
          if (verdict.isBlock) return OutboundMcpGuardDecision.deny(verdict.message ?? 'denied');
          return const OutboundMcpGuardDecision.allow();
        },
        auditLogger: auditLogger,
      );
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final allowed = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: {'text': 'ok'},
        caller: const OutboundMcpCaller(sessionId: 'session-1', principal: 'principal-1'),
      );
      final denied = await pool.callTool(
        serverName: 'linear',
        toolName: 'delete_project',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 'session-1', principal: 'principal-1'),
      );

      expect(allowed.isSuccess, isTrue);
      expect(denied.error!.code, 'egress_denied');
      final lines = File(auditLogger.auditFilePath).readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();
      expect(lines, hasLength(2));
      final allowedEntry = jsonDecode(lines.first) as Map<String, dynamic>;
      final deniedEntry = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(allowedEntry, containsPair('server', 'linear'));
      expect(allowedEntry, containsPair('tool', 'list_issues'));
      expect(allowedEntry, containsPair('decision', 'allow'));
      expect(allowedEntry, containsPair('principal', 'principal-1'));
      expect(allowedEntry, containsPair('credentialRef', 'linear-token'));
      expect(deniedEntry, containsPair('decision', 'deny'));
      expect(deniedEntry['reason'], contains('delete_project'));
      await pool.close();
    });

    test(
      'S-01 pool resolves credential references into transport options without exposing secrets in registry',
      () async {
        CredentialEntry? observedCredential;
        final pool = OutboundMcpPool(
          mcpServers: _registry({
            'linear': const McpServerEntry(
              command: 'fake',
              networkClass: McpNetworkClass.local,
              credential: 'linear-token',
            ),
          }),
          credentials: const CredentialsConfig(entries: {'linear-token': CredentialEntry(apiKey: 'secret-token')}),
          transportFactory: (server, options) async {
            observedCredential = options.credential;
            return _PoolTransport();
          },
          guardDecisionHook: _allow,
          auditLogger: GuardAuditLogger(),
        );

        addTearDown(pool.close);

        await pool.listTools('linear');

        expect(observedCredential?.secret, 'secret-token');
        expect(pool.toString(), isNot(contains('secret-token')));
      },
    );

    test('S-01 credentialed server fails closed when credentials are omitted', () async {
      var transportConstructed = false;
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': const McpServerEntry(
            url: 'https://linear.example/mcp',
            networkClass: McpNetworkClass.public,
            credential: 'linear-token',
          ),
        }),
        transportFactory: (server, options) async {
          transportConstructed = true;
          return _PoolTransport();
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );
      addTearDown(pool.close);

      final result = await pool.callTool(
        serverName: 'linear',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(result.error!.code, 'credential_unavailable');
      expect(transportConstructed, isFalse);
    });

    test('S-01 credentialed stdio server fails closed when the credential declares no env var to inject', () async {
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': const McpServerEntry(
            command: 'fake',
            networkClass: McpNetworkClass.local,
            credential: 'linear-token',
          ),
        }),
        credentials: const CredentialsConfig(entries: {'linear-token': CredentialEntry(apiKey: 'secret-token')}),
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );
      addTearDown(pool.close);

      final result = await pool.callTool(
        serverName: 'linear',
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(result.error!.code, 'credential_env_unmapped');
    });

    test('rate limit rejects before transport, audits once, and resets by window', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final tempDir = Directory.systemTemp.createTempSync('egress_rate_limit_audit_test_');
      final auditLogger = GuardAuditLogger(dataDir: tempDir.path);
      final transport = _PoolTransport();
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': McpServerEntry(
            command: 'fake',
            networkClass: McpNetworkClass.local,
            rateLimit: const McpServerRateLimit(calls: 1, window: Duration(seconds: 10)),
          ),
        }),
        transportFactory: (server, options) async => transport,
        guardDecisionHook: _allow,
        auditLogger: auditLogger,
        clock: () => now,
      );
      addTearDown(() async {
        await pool.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final first = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: {'text': 'first'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      final denied = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: {'text': 'second'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      now = now.add(const Duration(seconds: 11));
      final afterReset = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: {'text': 'after'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(first.isSuccess, isTrue);
      expect(denied.error!.code, 'egress_denied');
      expect(denied.reason, contains('rate limit'));
      expect(afterReset.isSuccess, isTrue);
      expect(transport.callCount, 2);
      final entries = File(auditLogger.auditFilePath).readAsLinesSync().map((line) {
        return jsonDecode(line) as Map<String, dynamic>;
      }).toList();
      expect(entries, hasLength(3));
      expect(entries[1], containsPair('decision', 'deny'));
      expect(entries[1]['reason'], contains('rate limit'));
    });

    test('concurrent rate-limit admission rejects the second call before transport', () async {
      final auditLogger = _BlockingAllowAuditLogger();
      final transport = _PoolTransport();
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': McpServerEntry(
            command: 'fake',
            networkClass: McpNetworkClass.local,
            rateLimit: const McpServerRateLimit(calls: 1, window: Duration(seconds: 10)),
          ),
        }),
        transportFactory: (server, options) async => transport,
        guardDecisionHook: _allow,
        auditLogger: auditLogger,
        clock: () => DateTime.utc(2026, 1, 1, 12),
      );
      addTearDown(pool.close);

      final first = pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: {'text': 'first'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      await auditLogger.firstAllowedWrite.timeout(const Duration(seconds: 1));

      final second = await pool
          .callTool(
            serverName: 'linear',
            toolName: 'list_issues',
            arguments: {'text': 'second'},
            caller: const OutboundMcpCaller(sessionId: 's1'),
          )
          .timeout(const Duration(seconds: 1));
      expect(transport.callCount, 0);
      auditLogger.releaseAllowedWrites();
      await first;

      expect(second.error!.code, 'egress_denied');
      expect(second.reason, contains('rate limit'));
      expect(transport.callCount, 1);
    });

    test('token budget consumes outboundCallTokens and rejects until window reset', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final transport = _PoolTransport(outboundCallTokens: 7);
      final bus = EventBus();
      final events = <OutboundMcpGovernanceEvent>[];
      final subscription = bus.on<OutboundMcpGovernanceEvent>().listen(events.add);
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': McpServerEntry(
            command: 'fake',
            networkClass: McpNetworkClass.local,
            tokenBudget: const McpServerTokenBudget(tokens: 7, window: Duration(seconds: 10)),
          ),
        }),
        transportFactory: (server, options) async => transport,
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
        eventBus: bus,
        clock: () => now,
      );
      addTearDown(() async {
        await subscription.cancel();
        await bus.dispose();
        await pool.close();
      });

      final first = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      final denied = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      now = now.add(const Duration(seconds: 11));
      final afterReset = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.outboundCallTokens, 7);
      expect(denied.error!.code, 'egress_denied');
      expect(denied.reason, contains('token budget'));
      expect(afterReset.isSuccess, isTrue);
      expect(transport.callCount, 2);
      expect(events.map((event) => event.tokensUsed), contains(7));
      expect(events.last.rejections, 0);
      expect(events.any((event) => event.rejectionReason?.contains('token budget') ?? false), isTrue);
    });

    test('surfaced tools are listed selectively while un-surfaced tools remain dispatchable', () async {
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': const McpServerEntry(
            command: 'fake',
            networkClass: McpNetworkClass.local,
            surfaceTools: ['list_issues'],
          ),
        }),
        transportFactory: (server, options) async => _PoolTransport(toolNames: const ['list_issues', 'delete_project']),
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );
      addTearDown(pool.close);

      final tools = await pool.listTools('linear');
      final result = await pool.callTool(
        serverName: 'linear',
        toolName: 'delete_project',
        arguments: {'text': 'ok'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(tools.map((tool) => tool.name), ['list_issues']);
      expect(result.isSuccess, isTrue);
      expect(result.content.single['text'], 'ok');
    });

    test('surface tool unknown to server fails load validation', () async {
      final pool = OutboundMcpPool(
        mcpServers: _registry({
          'linear': const McpServerEntry(
            command: 'fake',
            networkClass: McpNetworkClass.local,
            surfaceTools: ['does_not_exist'],
          ),
        }),
        transportFactory: (server, options) async => _PoolTransport(toolNames: const ['list_issues']),
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(),
      );
      addTearDown(pool.close);

      await expectLater(
        pool.listTools('linear'),
        throwsA(
          isA<OutboundMcpException>()
              .having((error) => error.message, 'message', contains('linear'))
              .having((error) => error.message, 'message', contains('does_not_exist')),
        ),
      );
    });

    test('audit write failure denies otherwise allowed egress', () async {
      final tempFile = File('${Directory.systemTemp.createTempSync('egress_audit_fail_').path}/not_a_directory')
        ..writeAsStringSync('occupied');
      addTearDown(() {
        final parent = tempFile.parent;
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      });
      var dispatches = 0;
      final pool = OutboundMcpPool(
        mcpServers: _registry({'linear': const McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local)}),
        transportFactory: (server, options) async {
          dispatches++;
          return _PoolTransport();
        },
        guardDecisionHook: _allow,
        auditLogger: GuardAuditLogger(dataDir: tempFile.path),
      );

      final result = await pool.callTool(
        serverName: 'linear',
        toolName: 'list_issues',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 'session-1'),
      );

      expect(result.error!.code, 'egress_denied');
      expect(result.reason, contains('guard/audit failure'));
      expect(dispatches, 0);
    });
  });

  group('stdioCredentialEnvironment', () {
    test('injects the resolved secret under each declared credential env var', () {
      final env = stdioCredentialEnvironment(
        const CredentialEntry(apiKey: 'sk-acme-123', envVars: ['ACME_API_KEY', 'ACME_TOKEN']),
      );
      expect(env, {'ACME_API_KEY': 'sk-acme-123', 'ACME_TOKEN': 'sk-acme-123'});
    });

    test('fails closed when the credential declares no env var to target', () {
      expect(
        () => stdioCredentialEnvironment(const CredentialEntry(apiKey: 'sk-acme-123')),
        throwsA(isA<OutboundMcpException>().having((e) => e.code, 'code', 'credential_env_unmapped')),
      );
    });
  });
}

McpServersConfig _registry(Map<String, McpServerEntry> entries) => McpServersConfig(entries: entries);

Future<OutboundMcpGuardDecision> _allow(OutboundMcpGuardRequest request) async =>
    const OutboundMcpGuardDecision.allow();

final class _BlockingAllowAuditLogger extends GuardAuditLogger {
  final _firstAllowedWrite = Completer<void>();
  final _releaseAllowedWrites = Completer<void>();

  Future<void> get firstAllowedWrite => _firstAllowedWrite.future;

  void releaseAllowedWrites() {
    if (!_releaseAllowedWrites.isCompleted) {
      _releaseAllowedWrites.complete();
    }
  }

  @override
  Future<void> writeEntry(AuditEntry entry) async {
    if (entry.decision == 'allow') {
      if (!_firstAllowedWrite.isCompleted) {
        _firstAllowedWrite.complete();
      }
      await _releaseAllowedWrites.future;
    }
    await super.writeEntry(entry);
  }
}

final class _PoolTransport implements OutboundMcpTransport {
  final bool failCalls;
  final bool failToolsList;
  final bool failClose;
  final List<String> toolNames;
  final int? outboundCallTokens;
  var healthy = true;
  var closed = false;
  var callCount = 0;
  Completer<void>? _pingStarted;
  Completer<bool>? _pingResult;

  _PoolTransport({
    this.failCalls = false,
    this.failToolsList = false,
    this.failClose = false,
    this.toolNames = const ['echo'],
    this.outboundCallTokens,
  });

  Future<void> get pingStarted => _pingStarted!.future;

  void blockPing() {
    _pingStarted = Completer<void>();
    _pingResult = Completer<bool>();
  }

  void releasePing(bool result) {
    _pingResult!.complete(result);
  }

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    if (method == 'initialize') return const {};
    if (method == 'tools/list') {
      if (failToolsList) {
        throw const OutboundMcpException('startup_list_failed', 'startup list failed');
      }
      return {
        'tools': [
          for (final name in toolNames) {'name': name},
        ],
      };
    }
    if (failCalls) {
      throw const OutboundMcpException('timeout', 'timed out');
    }
    callCount++;
    final args = params['arguments'] as Map?;
    return {
      'content': [
        {'type': 'text', 'text': args?['text']?.toString() ?? ''},
      ],
      if (outboundCallTokens != null) 'outboundCallTokens': outboundCallTokens,
    };
  }

  @override
  Future<void> sendNotification(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {}

  @override
  Future<bool> ping({required Duration timeout, required int maxResponseBytes}) async {
    final pingResult = _pingResult;
    if (pingResult != null) {
      _pingStarted!.complete();
      return pingResult.future;
    }
    return healthy;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (failClose) {
      throw StateError('close failed');
    }
  }
}

final class _ManualTimer implements Timer {
  final void Function() _callback;
  var _isActive = true;

  _ManualTimer(this._callback);

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }

  @override
  void cancel() {
    _isActive = false;
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;
}
