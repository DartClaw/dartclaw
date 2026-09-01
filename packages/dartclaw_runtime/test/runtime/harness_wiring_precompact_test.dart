import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during harness wiring test');

Future<T> _pollFor<T>(T Function() read, bool Function(T) isReady) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  var value = read();
  while (!isReady(value) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    value = read();
  }
  return value;
}

void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_precompact_wiring_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(
            executable: Platform.resolvedExecutable,
            poolSize: 1,
            options: const {'credentials_required': false},
          ),
        },
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    await writeWorkspacePromptFiles(config.workspaceDir);
    eventBus = EventBus();
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('Claude PreCompact persists a bounded canonical observation before acknowledgement', () async {
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
    final process = CapturingFakeProcess(
      stdoutController: StreamController<List<int>>(),
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final factory = HarnessFactory()
      ..register('claude', (factoryConfig) {
        return ClaudeCodeHarness(
          claudeExecutable: factoryConfig.executable,
          cwd: factoryConfig.cwd,
          turnTimeout: factoryConfig.turnTimeout,
          processFactory:
              (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
                scheduleMicrotask(() {
                  process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
                });
                return process;
              },
          commandProbe: (_, _) async => ProcessResult(0, 0, '2.0.0', ''),
          delayFactory: (_) async {},
          environment: factoryConfig.environment,
          providerOptions: factoryConfig.providerOptions,
          onMemoryApply: factoryConfig.onMemoryApply,
          onMemoryObserve: factoryConfig.onMemoryObserve,
          onContextualMemoryApply: factoryConfig.onContextualMemoryApply,
          onContextualMemoryObserve: factoryConfig.onContextualMemoryObserve,
          onMemorySearch: factoryConfig.onMemorySearch,
          onMemoryRead: factoryConfig.onMemoryRead,
          onPermissionDenied: factoryConfig.onPermissionDenied,
          harnessConfig: factoryConfig.harnessConfig,
          historyConfig: factoryConfig.historyConfig,
          guardChain: factoryConfig.guardChain,
          auditLogger: factoryConfig.auditLogger,
          protocolAdapter: ClaudeProtocolAdapter(ownMcpToolCanonicals: factoryConfig.ownMcpToolCanonicals),
        );
      });
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: factory,
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
    );

    final session = await storage!.sessions.getOrCreateMainSession();
    final persistedContext = 'Keep this decision before compaction. ${'x' * (40 * 1024)}';
    await storage!.messages.insertMessage(sessionId: session.id, role: 'assistant', content: 'Earlier context');
    await storage!.messages.insertMessage(sessionId: session.id, role: 'user', content: persistedContext);
    final turn = harnessWiring!.primaryHarness.turn(
      sessionId: session.id,
      messages: [
        {'role': 'user', 'content': persistedContext},
      ],
      systemPrompt: harnessWiring!.harnessConfig.appendSystemPrompt ?? '',
    );
    await _pollFor(() => process.capturedStdinJson.any((message) => message['type'] == 'user'), (ready) => ready);

    process.emitStdout(
      jsonEncode({
        'type': 'control_request',
        'request_id': 'pre-compact-capture',
        'request': {
          'subtype': 'hook_callback',
          'input': {'hook_event_name': 'PreCompact', 'session_id': 'provider-native-session', 'trigger': 'auto'},
        },
      }),
    );
    final acknowledged = await _pollFor(
      () => process.capturedStdinJson.any(
        (message) => (message['response'] as Map?)?['request_id'] == 'pre-compact-capture',
      ),
      (ready) => ready,
    );
    expect(acknowledged, isTrue);

    final corpus = await storage!.memoryCorpus.readCorpus();
    final observation = corpus.observations.expand((document) => document.observations).single;
    expect(
      observation.content,
      startsWith('Pre-compaction conversation context (auto):\n[assistant] Earlier context\n[user] Keep this decision'),
    );
    expect(utf8.encode(observation.content).length, lessThanOrEqualTo(32 * 1024));
    expect(observation.provenance.sourceLocator, 'session:${session.id}');
    expect(observation.provenance.sourceEvent, startsWith('pre-compact:'));
    expect(observation.provenance.sessionRef, session.id);
    expect(observation.provenance.caller, 'claude:PreCompact');

    process.emitStdout(jsonEncode({'type': 'result', 'result': 'done', 'is_error': false}));
    await turn;
  });
}
