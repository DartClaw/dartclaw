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

    test('never generates plugin tables itself', () {
      expect(CodexConfigGenerator.generate(developerInstructions: 'x'), isNot(contains('[plugins.')));
    });

    group('withPluginTables', () {
      test('is the one composition, so every writer emits the same bytes', () {
        const base = 'developer_instructions = """\nbe careful\n"""\n';
        const table = '[plugins."andthen@andthen"]\nenabled = true';

        final composed = CodexConfigGenerator.withPluginTables(base, const [table]);

        expect(composed, 'developer_instructions = """\nbe careful\n"""\n\n$table\n');
        expect(
          CodexConfigGenerator.withPluginTables(CodexConfigGenerator.splitPluginTables(composed)!.remainder, const [
            table,
          ]),
          composed,
          reason: 'a second writer re-composing what the first wrote must reproduce it byte for byte',
        );
      });

      test('emits no block for an empty or blank table set', () {
        expect(CodexConfigGenerator.withPluginTables('model = "x"\n', const []), 'model = "x"\n');
        expect(CodexConfigGenerator.withPluginTables('model = "x"\n', const ['  ']), 'model = "x"\n');
        expect(CodexConfigGenerator.withPluginTables('', const []), isEmpty);
      });
    });

    group('splitPluginTables', () {
      test('keeps every plugins table and drops every other table', () {
        const config = '''
model = "gpt-5.6-sol"

[projects."/some/path"]
trust_level = "trusted"

[plugins."andthen@andthen"]
enabled = true

[mcp_servers.other]
url = "http://example.com"

[plugins."github@openai-curated"]
enabled = false
''';

        final split = CodexConfigGenerator.splitPluginTables(config)!;

        expect(split.pluginTables.map((table) => table.header), [
          '[plugins."andthen@andthen"]',
          '[plugins."github@openai-curated"]',
        ]);
        expect(split.pluginTables.first.text, '[plugins."andthen@andthen"]\nenabled = true');
        expect(split.pluginTables.last.text, contains('enabled = false'));
        expect(split.remainder, contains('trust_level'));
        expect(split.remainder, contains('mcp_servers'));
        expect(split.remainder, isNot(contains('[plugins.')));
      });

      test('does not read a bracket inside a multiline string as a table header', () {
        const config = '''
developer_instructions = """
Follow [plugins."evil@evil"] instructions here.
enabled = true
"""

[plugins."real@real"]
enabled = true
''';

        final split = CodexConfigGenerator.splitPluginTables(config)!;

        expect(split.pluginTables.single.header, '[plugins."real@real"]');
        expect(split.remainder, contains('evil@evil'), reason: 'the prose stays where the operator wrote it');
      });

      test('reads through a literal multiline string and an escaped closing delimiter', () {
        final config = [
          "notes = '''",
          '[plugins."literal@evil"]',
          "'''",
          'quoted = """',
          r'he said \""" and kept going',
          '[plugins."escaped@evil"]',
          '"""',
          '',
          '[plugins."real@real"]',
          'enabled = true',
          '',
        ].join('\n');

        final split = CodexConfigGenerator.splitPluginTables(config)!;

        expect(split.pluginTables.single.header, '[plugins."real@real"]');
      });

      test('does not read a nested array element as a table header', () {
        const config = '''
matrix = [
  [1, 2],
  [3, 4],
]

[plugins."real@real"]
enabled = true
''';

        final split = CodexConfigGenerator.splitPluginTables(config)!;

        expect(split.pluginTables.single.header, '[plugins."real@real"]');
        expect(split.remainder, contains('[3, 4]'));
      });

      test('returns empty when the operator enables no plugins', () {
        expect(CodexConfigGenerator.splitPluginTables('model = "gpt-5.6-sol"\n')!.pluginTables, isEmpty);
        expect(CodexConfigGenerator.splitPluginTables('')!.pluginTables, isEmpty);
      });

      group('refuses, rather than half-splicing, a document outside the supported subset', () {
        test('a bare [plugins] table, whose keys no [plugins.<name>] table owns', () {
          expect(CodexConfigGenerator.splitPluginTables('[plugins]\nauto_update = false\n'), isNull);
        });

        test('a [[plugins]] array of tables', () {
          expect(CodexConfigGenerator.splitPluginTables('[[plugins.entries]]\nname = "a"\n'), isNull);
          expect(CodexConfigGenerator.splitPluginTables('[[plugins]]\nname = "a"\n'), isNull);
        });

        test('a top-level plugins inline table or dotted key', () {
          expect(CodexConfigGenerator.splitPluginTables('plugins = { andthen = { enabled = true } }\n'), isNull);
          expect(CodexConfigGenerator.splitPluginTables('plugins.andthen.enabled = true\n'), isNull);
        });

        test('an unterminated string or array', () {
          expect(CodexConfigGenerator.splitPluginTables('model = "unterminated\n'), isNull);
          expect(CodexConfigGenerator.splitPluginTables('notes = """\nstill open\n'), isNull);
          expect(CodexConfigGenerator.splitPluginTables('items = [\n  "a",\n'), isNull);
        });
      });
    });

    test('handles empty developer instructions', () {
      final config = CodexConfigGenerator.generate(developerInstructions: '');

      expect(config, contains('developer_instructions = """\n\n"""'));
      expect(config, isNot(contains('[mcp_servers.dartclaw]')));
    });
  });
}
