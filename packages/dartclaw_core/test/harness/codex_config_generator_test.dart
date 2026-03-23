import 'package:dartclaw_core/src/harness/codex_config_generator.dart';
import 'package:test/test.dart';

void main() {
  group('CodexConfigGenerator', () {
    test('generates config.toml with developer instructions and MCP section', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'use caution',
        mcpServerUrl: 'http://127.0.0.1:3333/mcp',
        mcpBearerTokenEnvVar: 'DARTCLAW_MCP_TOKEN',
      );

      expect(config, contains('developer_instructions = """'));
      expect(config, contains('use caution'));
      expect(config, contains('[mcp_servers.dartclaw]'));
      expect(config, contains('url = "http://127.0.0.1:3333/mcp"'));
      expect(config, contains('bearer_token_env_var = "DARTCLAW_MCP_TOKEN"'));
    });

    test('escapes embedded triple quotes in developer instructions', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'alpha """ beta',
      );

      expect(config, contains(r'\"""'));
      expect(config, isNot(contains('alpha """ beta')));
    });

    test('omits MCP section when URL is null', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'standalone',
      );

      expect(config, contains('developer_instructions = """'));
      expect(config, isNot(contains('[mcp_servers.dartclaw]')));
      expect(config, isNot(contains('bearer_token_env_var')));
    });

    test('uses the default bearer token env var when MCP URL is configured', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'use tools carefully',
        mcpServerUrl: 'http://127.0.0.1:3333/mcp',
      );

      expect(config, contains('[mcp_servers.dartclaw]'));
      expect(
        config,
        contains(
          'bearer_token_env_var = "${CodexConfigGenerator.defaultMcpBearerTokenEnvVar}"',
        ),
      );
    });

    test('omits MCP section when URL is blank', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'standalone',
        mcpServerUrl: '   ',
      );

      expect(config, isNot(contains('[mcp_servers.dartclaw]')));
      expect(config, isNot(contains('bearer_token_env_var')));
    });

    test('handles empty developer instructions', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: '',
      );

      expect(config, contains('developer_instructions = """\n\n"""'));
      expect(config, isNot(contains('[mcp_servers.dartclaw]')));
    });
  });
}
