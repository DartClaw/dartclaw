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
      final config = CodexConfigGenerator.generate(developerInstructions: 'alpha """ beta');

      expect(config, contains(r'\"""'));
      expect(config, isNot(contains('alpha """ beta')));
    });

    test('omits MCP section when URL is null', () {
      final config = CodexConfigGenerator.generate(developerInstructions: 'standalone');

      expect(config, contains('developer_instructions = """'));
      expect(config, isNot(contains('[mcp_servers.dartclaw]')));
      expect(config, isNot(contains('bearer_token_env_var')));
    });

    test('uses the default bearer token env var when MCP URL is configured', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'use tools carefully',
        mcpServerUrl: 'http://127.0.0.1:3333/mcp',
        mcpBearerTokenEnvVar: CodexConfigGenerator.defaultMcpBearerTokenEnvVar,
      );

      expect(config, contains('[mcp_servers.dartclaw]'));
      expect(config, contains('bearer_token_env_var = "${CodexConfigGenerator.defaultMcpBearerTokenEnvVar}"'));
    });

    test('omits bearer token configuration for an unauthenticated loopback MCP server', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'use tools carefully',
        mcpServerUrl: 'http://127.0.0.1:3333/mcp',
      );

      expect(config, contains('[mcp_servers.dartclaw]'));
      expect(config, isNot(contains('bearer_token_env_var')));
    });

    test('omits MCP section when URL is blank', () {
      final config = CodexConfigGenerator.generate(developerInstructions: 'standalone', mcpServerUrl: '   ');

      expect(config, isNot(contains('[mcp_servers.dartclaw]')));
      expect(config, isNot(contains('bearer_token_env_var')));
    });

    test('selects the custom Responses gateway provider with client auth disabled', () {
      final config = CodexConfigGenerator.generate(
        developerInstructions: 'be careful',
        gatewayBaseUrl: 'http://127.0.0.1:8080/v1',
      );

      expect(config, contains('model_provider = "dartclaw"'));
      expect(config, contains('[model_providers.dartclaw]'));
      expect(config, contains('base_url = "http://127.0.0.1:8080/v1"'));
      expect(config, contains('wire_api = "responses"'));
      expect(config, contains('requires_openai_auth = false'));
    });

    test('leaves provider selection to Codex when no gateway is configured', () {
      final config = CodexConfigGenerator.generate(developerInstructions: 'host run');

      expect(config, isNot(contains('model_provider')));
      expect(config, isNot(contains('model_providers')));
    });

    test('turns off provider-native web search only when asked', () {
      expect(
        CodexConfigGenerator.generate(developerInstructions: 'x', nativeWebSearch: false),
        contains('[tools]\nweb_search = false'),
      );
      expect(CodexConfigGenerator.generate(developerInstructions: 'x'), isNot(contains('web_search')));
    });

    test('handles empty developer instructions', () {
      final config = CodexConfigGenerator.generate(developerInstructions: '');

      expect(config, contains('developer_instructions = """\n\n"""'));
      expect(config, isNot(contains('[mcp_servers.dartclaw]')));
    });
  });
}
