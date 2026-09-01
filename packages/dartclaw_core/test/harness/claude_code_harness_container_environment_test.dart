import 'dart:io';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/claude_protocol.dart' show containerClaudePlaceholderApiKey;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  test('request-scoped environment reaches the concrete Claude container launch', () async {
    final hostRoot = await Directory.systemTemp.createTemp('claude-container-step-env');
    addTearDown(() async {
      if (await hostRoot.exists()) await hostRoot.delete(recursive: true);
    });
    final container = FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace');
    final harness = ClaudeCodeHarness(
      cwd: hostRoot.path,
      processFactory: defaultClaudeProcessFactory,
      commandProbe: defaultClaudeCommandProbe,
      delayFactory: noOpClaudeDelay,
      environment: const {'ANTHROPIC_API_KEY': 'host-secret'},
      containerEnvironment: const {
        'DARTCLAW_STEP_ARTIFACTS_DIR': '/workspace/artifacts',
        'ANDTHEN_REPORT_PATH': '/workspace/artifacts/report.md',
      },
      containerManager: container,
    );
    addTearDown(harness.dispose);

    await harness.start();

    expect(container.lastEnv?['DARTCLAW_STEP_ARTIFACTS_DIR'], '/workspace/artifacts');
    expect(container.lastEnv?['ANDTHEN_REPORT_PATH'], '/workspace/artifacts/report.md');
    expect(container.lastEnv?['ANTHROPIC_API_KEY'], containerClaudePlaceholderApiKey);
    expect(container.lastEnv?.values, isNot(contains('host-secret')));
  });

  test('the container-mode MCP config is readable by the image user and carries no bearer', () async {
    // Native Linux bind mounts pass ownership through verbatim: the host writes
    // the file, the image's uid-1000 user reads it. Owner-only would lock it out.
    final hostRoot = await Directory.systemTemp.createTemp('claude-container-mcp-config');
    addTearDown(() async {
      if (await hostRoot.exists()) await hostRoot.delete(recursive: true);
    });
    final container = FakeClaudeContainerExecutor(
      hostRoot: hostRoot.path,
      containerRoot: '/workspace',
      mcpBridgeUrl: 'http://127.0.0.1:8081/mcp',
    );
    Directory(container.generatedStateDir).createSync(recursive: true);
    final harness = ClaudeCodeHarness(
      cwd: hostRoot.path,
      processFactory: defaultClaudeProcessFactory,
      commandProbe: defaultClaudeCommandProbe,
      delayFactory: noOpClaudeDelay,
      environment: const {'ANTHROPIC_API_KEY': 'host-secret'},
      containerManager: container,
    );
    addTearDown(harness.dispose);

    await harness.start();

    final command = container.lastCommand;
    final configArg = command[command.indexOf('--mcp-config') + 1];
    final configFile = File(p.join(container.generatedStateDir, p.basename(configArg)));
    expect(configFile.readAsStringSync(), allOf(contains('http://127.0.0.1:8081/mcp'), isNot(contains('Bearer'))));
    if (!Platform.isWindows) {
      expect(configFile.statSync().mode & 0x004, 0x004, reason: 'world-readable for the image uid');
    }
  });
}
