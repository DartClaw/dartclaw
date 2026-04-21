import 'dart:io';

import 'package:dartclaw_core/src/harness/codex_environment.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CodexEnvironment', () {
    group('isolated mode (useSystemCodexHome: false)', () {
      test('setup writes config.toml, AGENTS.md, and environment overrides', () async {
        final env = CodexEnvironment(
          developerInstructions: 'follow the rules',
          mcpServerUrl: 'http://127.0.0.1:3333/mcp',
          mcpGatewayToken: 'test-token',
          agentsMdContent: '# agent notes',
          useSystemCodexHome: false,
        );
        addTearDown(env.cleanup);

        expect(env.isSetup, isFalse);

        final dirPath = await env.setup();
        final repeatedSetupPath = await env.setup();

        expect(env.isSetup, isTrue);
        expect(Directory(dirPath).existsSync(), isTrue);
        expect(repeatedSetupPath, dirPath);

        final configFile = File(p.join(dirPath, 'config.toml'));
        final agentsFile = File(p.join(dirPath, 'AGENTS.md'));

        expect(configFile.existsSync(), isTrue);
        expect(agentsFile.existsSync(), isTrue);
        expect(configFile.readAsStringSync(), contains('developer_instructions = """'));
        expect(configFile.readAsStringSync(), contains('[mcp_servers.dartclaw]'));
        expect(configFile.readAsStringSync(), contains('bearer_token_env_var = "DARTCLAW_MCP_TOKEN"'));
        expect(agentsFile.readAsStringSync(), contains('# agent notes'));

        final overrides = env.environmentOverrides();
        expect(overrides['CODEX_HOME'], dirPath);
        expect(overrides['DARTCLAW_MCP_TOKEN'], 'test-token');
      });

      test('setup leaves AGENTS.md absent when agents content is not provided', () async {
        final env = CodexEnvironment(
          developerInstructions: 'follow the rules',
          mcpServerUrl: 'http://127.0.0.1:3333/mcp',
          useSystemCodexHome: false,
        );
        addTearDown(env.cleanup);

        expect(env.environmentOverrides(), isEmpty);

        final dirPath = await env.setup();
        final configFile = File(p.join(dirPath, 'config.toml'));
        final agentsFile = File(p.join(dirPath, 'AGENTS.md'));

        expect(configFile.existsSync(), isTrue);
        expect(configFile.readAsStringSync(), contains('developer_instructions = """'));
        expect(agentsFile.existsSync(), isFalse);
        expect(env.environmentOverrides(), {'CODEX_HOME': dirPath});
      });

      test('cleanup removes the temp directory and is safe to call twice', () async {
        final env = CodexEnvironment(
          developerInstructions: 'cleanup test',
          useSystemCodexHome: false,
        );
        final dirPath = await env.setup();
        final tempDir = Directory(dirPath);

        expect(tempDir.existsSync(), isTrue);
        expect(env.isSetup, isTrue);

        await env.cleanup();

        expect(tempDir.existsSync(), isFalse);
        expect(env.isSetup, isFalse);
        expect(env.environmentOverrides(), isEmpty);
        expect(() async => env.cleanup(), returnsNormally);
      });
    });

    group('system mode (useSystemCodexHome: true, the default)', () {
      test('setup returns ~/.codex without mutating anything and default is true', () async {
        final env = CodexEnvironment(developerInstructions: 'anything');
        // Default value check — no explicit param.
        expect(env.useSystemCodexHome, isTrue);
        expect(env.isSetup, isTrue, reason: 'system mode is considered set up before setup() runs');

        final home = Platform.environment['HOME']!;
        final dirPath = await env.setup();
        expect(dirPath, p.join(home, '.codex'));
        expect(
          env.environmentOverrides().containsKey('CODEX_HOME'),
          isFalse,
          reason: 'system mode must NOT override CODEX_HOME — subprocess inherits from parent env',
        );
      });

      test('setup still exports the MCP bearer token env var when configured', () async {
        final env = CodexEnvironment(
          developerInstructions: 'irrelevant',
          mcpGatewayToken: 'bearer-xyz',
        );
        await env.setup();
        final overrides = env.environmentOverrides();
        expect(overrides, {'DARTCLAW_MCP_TOKEN': 'bearer-xyz'});
      });

      test('cleanup is a no-op in system mode', () async {
        final env = CodexEnvironment(developerInstructions: 'nothing to clean');
        await env.setup();
        await env.cleanup();
        expect(() async => env.cleanup(), returnsNormally);
      });
    });
  });
}
