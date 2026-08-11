import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show ExecutionPolicy;
import 'package:dartclaw_core/dartclaw_core.dart'
    show containerClaudeExecutable, containerClaudePlaceholderApiKey, containerCodexExecutable;
import 'package:dartclaw_server/src/task/workflow_cli_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_cli_runner_test_support.dart';

/// Distinct sentinels for every host-side secret a containerized one-shot must
/// never expose, so a leak names its own source.
const _anthropicKeySentinel = 'sk-ant-HOST-API-KEY-SENTINEL';
const _openAiKeySentinel = 'sk-openai-HOST-API-KEY-SENTINEL';
const _sharedMcpBearerSentinel = 'shared-operator-MCP-BEARER-SENTINEL';

const _hostProviderEnvironment = <String, String>{
  'ANTHROPIC_API_KEY': _anthropicKeySentinel,
  'OPENAI_API_KEY': _openAiKeySentinel,
  'DARTCLAW_MCP_TOKEN': _sharedMcpBearerSentinel,
};

const _claudeResult = '{"type":"result","session_id":"one-shot","result":"ok"}';
const _codexEvents =
    '{"type":"thread.started","thread_id":"codex-thread"}\n'
    '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}';

/// Every container-visible surface a secret could ride out on.
List<String> _inspectableSurfaces(FakeContainerExecutor container) => [
  container.lastCommand.join(' '),
  container.lastEnv?.entries.map((entry) => '${entry.key}=${entry.value}').join(' ') ?? '',
  for (final entry in Directory(container.generatedStateDir).listSync(recursive: true).whereType<File>())
    entry.readAsStringSync(),
];

void main() {
  late Directory workingDirectory;

  setUp(() {
    workingDirectory = Directory.systemTemp.createTempSync('one-shot-container-');
  });

  tearDown(() {
    if (workingDirectory.existsSync()) workingDirectory.deleteSync(recursive: true);
  });

  FakeContainerExecutor containerFor({
    required String stdout,
    String profileId = 'workspace',
    String? mcpBridgeUrl,
    bool executableRunnable = true,
  }) => FakeContainerExecutor(
    hostRoot: workingDirectory.path,
    containerRoot: '/workspace',
    profileId: profileId,
    mcpBridgeUrl: mcpBridgeUrl,
    executableRunnable: executableRunnable,
    stdout: stdout,
  );

  WorkflowCliRunner runnerFor(String provider, FakeContainerExecutor container, {List<Set<String>>? grantedMcpTools}) =>
      WorkflowCliRunner(
        providers: {
          provider: WorkflowCliProviderConfig(
            // A host executable path and a fully-credentialed host environment,
            // exactly what a real deployment configures.
            executable: provider,
            environment: _hostProviderEnvironment,
          ),
        },
        containerAuthorities: fakeContainerAuthorities(container, grantedMcpTools: grantedMcpTools),
      );

  Future<void> runTurn(
    WorkflowCliRunner runner,
    String provider, {
    String profile = 'workspace',
    List<String>? allowedTools,
  }) => runner.executeTurn(
    provider: provider,
    prompt: 'Review this',
    workingDirectory: workingDirectory.path,
    policy: ExecutionPolicy.container(profile),
    allowedTools: allowedTools,
  );

  group('containerized one-shot placement', () {
    test('claude runs the image binary, not the configured host path', () async {
      final container = containerFor(stdout: _claudeResult);
      await runTurn(runnerFor('claude', container), 'claude');

      expect(container.lastCommand.first, containerClaudeExecutable);
      expect(container.lastWorkingDirectory, '/workspace');
    });

    test('codex runs the image binary, not the configured host path', () async {
      final container = containerFor(stdout: _codexEvents);
      await runTurn(runnerFor('codex', container), 'codex');

      expect(container.lastCommand.first, containerCodexExecutable);
      expect(container.lastWorkingDirectory, '/workspace');
    });
  });

  group('host credentials stay on the host', () {
    test('no claude spawn surface carries a host secret', () async {
      final container = containerFor(stdout: _claudeResult, mcpBridgeUrl: 'http://127.0.0.1:8081/mcp');
      await runTurn(runnerFor('claude', container), 'claude', allowedTools: ['web_fetch']);

      for (final surface in _inspectableSurfaces(container)) {
        for (final sentinel in [_anthropicKeySentinel, _openAiKeySentinel, _sharedMcpBearerSentinel]) {
          expect(surface, isNot(contains(sentinel)));
        }
      }
      // Hardening still applies; the host provider environment does not. The
      // only ANTHROPIC_API_KEY present is the non-credential placeholder that
      // gets the CLI past its local auth gate.
      expect(container.lastEnv, contains('CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'));
      expect(container.lastEnv!['ANTHROPIC_API_KEY'], containerClaudePlaceholderApiKey);
    });

    test('no codex spawn surface carries a host secret', () async {
      final container = containerFor(stdout: _codexEvents, mcpBridgeUrl: 'http://127.0.0.1:8081/mcp');
      await runTurn(runnerFor('codex', container), 'codex', allowedTools: ['web_fetch']);

      for (final surface in _inspectableSurfaces(container)) {
        for (final sentinel in [_anthropicKeySentinel, _openAiKeySentinel, _sharedMcpBearerSentinel]) {
          expect(surface, isNot(contains(sentinel)));
        }
      }
      // The generated home pointer is the only thing the process is told.
      expect(container.lastEnv!.keys, ['CODEX_HOME']);
    });
  });

  group('host-owned step contract survives the boundary', () {
    test('claude gets a placeholder key so its local auth gate lets it reach the bridge', () async {
      final container = containerFor(stdout: _claudeResult);
      await runTurn(runnerFor('claude', container), 'claude');

      expect(container.lastEnv!['ANTHROPIC_API_KEY'], containerClaudePlaceholderApiKey);
      expect(container.lastEnv!['ANTHROPIC_API_KEY'], isNot(_anthropicKeySentinel));
    });

    test('step-artifacts and merge-resolve variables cross, translated to container paths', () async {
      // Host-computed per-step contract, not a credential: shipped review steps
      // write their report to this directory and the host reads it back.
      final container = containerFor(stdout: _claudeResult);
      await runnerFor('claude', container).executeTurn(
        provider: 'claude',
        prompt: 'Review this',
        workingDirectory: workingDirectory.path,
        policy: const ExecutionPolicy.container('workspace'),
        extraEnvironment: {
          'DARTCLAW_STEP_ARTIFACTS_DIR': p.join(workingDirectory.path, 'artifacts', 'step-1'),
          'DARTCLAW_MERGE_RESOLVE_STORY_BRANCH': 'story/s03',
        },
      );

      expect(container.lastEnv!['DARTCLAW_STEP_ARTIFACTS_DIR'], '/workspace/artifacts/step-1');
      expect(container.lastEnv!['DARTCLAW_MERGE_RESOLVE_STORY_BRANCH'], 'story/s03');
    });

    test('an unmapped step-artifacts path is refused rather than silently dropped', () async {
      final container = containerFor(stdout: _claudeResult);

      await expectLater(
        runnerFor('claude', container).executeTurn(
          provider: 'claude',
          prompt: 'Review this',
          workingDirectory: workingDirectory.path,
          policy: const ExecutionPolicy.container('workspace'),
          extraEnvironment: {'DARTCLAW_STEP_ARTIFACTS_DIR': '/elsewhere/on/the/host'},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('DARTCLAW_STEP_ARTIFACTS_DIR'), contains('not mounted')),
          ),
        ),
      );
    });

    test('an unrunnable packaged CLI rejects before the turn is spawned', () async {
      for (final provider in ['claude', 'codex']) {
        final container = containerFor(stdout: _claudeResult, executableRunnable: false);

        await expectLater(
          runTurn(runnerFor(provider, container), provider),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('not runnable'))),
        );
        // Only the probe ran; no provider process was started.
        expect(container.lastCommand.last, '--version');
      }
    });
  });

  group('containerized codex client configuration', () {
    /// Reads the generated home the turn created, before its cleanup.
    Map<String, String> capturedHomeFiles(FakeContainerExecutor container) {
      final home = Directory(p.join(container.generatedStateDir, ''));
      return {
        for (final entry in home.listSync(recursive: true).whereType<File>())
          p.basename(entry.path): entry.readAsStringSync(),
      };
    }

    test('selects the custom Responses provider with client auth disabled', () async {
      final container = containerFor(stdout: _codexEvents);
      late String config;
      container.onExec = (_) => config = capturedHomeFiles(container)['config.toml']!;

      await runTurn(runnerFor('codex', container), 'codex');

      expect(config, contains('model_provider = "dartclaw"'));
      expect(config, contains('base_url = "http://127.0.0.1:8080/v1"'));
      expect(config, contains('wire_api = "responses"'));
      expect(config, contains('requires_openai_auth = false'));
      expect(config, isNot(contains('api.openai.com')));
    });

    test('disables provider-native web search only for the restricted profile', () async {
      final restricted = containerFor(stdout: _codexEvents, profileId: 'restricted');
      late String restrictedConfig;
      restricted.onExec = (_) => restrictedConfig = capturedHomeFiles(restricted)['config.toml']!;
      await runTurn(runnerFor('codex', restricted), 'codex', profile: 'restricted');

      final workspace = containerFor(stdout: _codexEvents);
      late String workspaceConfig;
      workspace.onExec = (_) => workspaceConfig = capturedHomeFiles(workspace)['config.toml']!;
      await runTurn(runnerFor('codex', workspace), 'codex');

      expect(restrictedConfig, contains('web_search = false'));
      expect(workspaceConfig, isNot(contains('web_search = false')));
    });

    test('deletes the generated home when the turn ends', () async {
      final container = containerFor(stdout: _codexEvents);
      await runTurn(runnerFor('codex', container), 'codex');

      final leftovers = Directory(
        container.generatedStateDir,
      ).listSync(recursive: true).whereType<File>().map((entry) => entry.path);
      expect(leftovers, isEmpty);
    });
  });

  group('scoped MCP for one-shot containers', () {
    test('grants only the canonical tools the step is allowed', () async {
      final granted = <Set<String>>[];
      final container = containerFor(stdout: _claudeResult, mcpBridgeUrl: 'http://127.0.0.1:8081/mcp');
      await runTurn(
        runnerFor('claude', container, grantedMcpTools: granted),
        'claude',
        // `Bash` is a provider-native name and `mcp_call` is the catch-all
        // canonical: neither may become a bridged grant.
        allowedTools: ['web_fetch', 'web_search', 'Bash', 'mcp_call'],
      );

      expect(granted.single, {'web_fetch', 'web_search'});
    });

    test('grants nothing when the step declares no tools', () async {
      final granted = <Set<String>>[];
      final container = containerFor(stdout: _claudeResult);
      await runTurn(runnerFor('claude', container, grantedMcpTools: granted), 'claude');

      expect(granted.single, isEmpty);
    });

    test('claude points at the execution bridge with no bearer', () async {
      final container = containerFor(stdout: _claudeResult, mcpBridgeUrl: 'http://127.0.0.1:8081/mcp');
      late String mcpConfig;
      container.onExec = (command) {
        final path = command[command.indexOf('--mcp-config') + 1];
        mcpConfig = File(p.join(container.generatedStateDir, p.basename(path))).readAsStringSync();
      };

      await runTurn(runnerFor('claude', container), 'claude', allowedTools: ['web_fetch']);

      expect(container.lastCommand, contains('--mcp-config'));
      expect(jsonDecode(mcpConfig), {
        'mcpServers': {
          'dartclaw': {'type': 'http', 'url': 'http://127.0.0.1:8081/mcp'},
        },
      });
      expect(mcpConfig, isNot(contains('Authorization')));
    });

    test('claude configures no MCP server when nothing was granted', () async {
      final container = containerFor(stdout: _claudeResult);
      await runTurn(runnerFor('claude', container), 'claude');

      expect(container.lastCommand, isNot(contains('--mcp-config')));
    });
  });

  group('provider-native web denial', () {
    List<String> denyRules(FakeContainerExecutor container) {
      final settings = container.lastCommand[container.lastCommand.indexOf('--settings') + 1];
      final permissions = (jsonDecode(settings) as Map<String, dynamic>)['permissions'] as Map<String, dynamic>;
      return (permissions['deny'] as List).cast<String>();
    }

    test('restricted claude denies the native web tools', () async {
      final container = containerFor(stdout: _claudeResult, profileId: 'restricted');
      await runTurn(runnerFor('claude', container), 'claude', profile: 'restricted');

      expect(denyRules(container), containsAll(['WebFetch', 'WebSearch']));
    });

    test('workspace claude keeps the native web tools', () async {
      final container = containerFor(stdout: _claudeResult);
      await runTurn(runnerFor('claude', container), 'claude');

      expect(container.lastCommand, isNot(contains('--settings')));
    });
  });

  group('bridgedMcpToolsFor', () {
    test('drops provider-native names and the catch-all canonical', () {
      expect(bridgedMcpToolsFor(['web_fetch', 'WebFetch', 'mcp_call', 'shell']), {'web_fetch', 'shell'});
    });

    test('is empty for a null or empty allowlist', () {
      expect(bridgedMcpToolsFor(null), isEmpty);
      expect(bridgedMcpToolsFor(const []), isEmpty);
    });
  });
}
