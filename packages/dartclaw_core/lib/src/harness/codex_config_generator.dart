/// The Codex `model_providers` key DartClaw's host gateway is published under.
const codexGatewayProviderId = 'dartclaw';

/// Generates isolated `config.toml` content for Codex app-server workers.
class CodexConfigGenerator {
  static const String defaultMcpBearerTokenEnvVar = 'DARTCLAW_MCP_TOKEN';

  /// Builds `config.toml` content using only static Codex config-layer fields.
  ///
  /// [gatewayBaseUrl] selects DartClaw's custom Responses provider and points it
  /// at that URL. Client-side authentication is disabled on it: the container
  /// holds no credential, and the host gateway supplies the upstream one. Pass
  /// `null` for host execution, which keeps Codex's own provider selection.
  ///
  /// [nativeWebSearch] `false` turns off Codex's provider-side web search. That
  /// tool executes at the provider rather than in the container, so it is also
  /// refused host-side – this is the client half of the same denial.
  static String generate({
    required String developerInstructions,
    String? mcpServerUrl,
    String? mcpBearerTokenEnvVar,
    String? gatewayBaseUrl,
    bool nativeWebSearch = true,
  }) {
    final buffer = StringBuffer()
      ..writeln('developer_instructions = """')
      ..writeln(_escapeMultilineBasicString(developerInstructions))
      ..writeln('"""');

    if (gatewayBaseUrl != null && gatewayBaseUrl.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('model_provider = "$codexGatewayProviderId"')
        ..writeln()
        ..writeln('[model_providers.$codexGatewayProviderId]')
        ..writeln('name = "DartClaw host gateway"')
        ..writeln('base_url = "${_escapeBasicString(gatewayBaseUrl.trim())}"')
        ..writeln('wire_api = "responses"')
        ..writeln('requires_openai_auth = false');
    }

    if (!nativeWebSearch) {
      buffer
        ..writeln()
        ..writeln('[tools]')
        ..writeln('web_search = false');
    }

    final trimmedMcpServerUrl = mcpServerUrl?.trim();
    if (trimmedMcpServerUrl != null && trimmedMcpServerUrl.isNotEmpty) {
      final bearerTokenEnvVar = mcpBearerTokenEnvVar?.trim();

      buffer
        ..writeln()
        ..writeln('[mcp_servers.dartclaw]')
        ..writeln('url = "${_escapeBasicString(trimmedMcpServerUrl)}"');
      if (bearerTokenEnvVar != null && bearerTokenEnvVar.isNotEmpty) {
        buffer.writeln('bearer_token_env_var = "${_escapeBasicString(bearerTokenEnvVar)}"');
      }
    }

    return buffer.toString();
  }

  static String _escapeMultilineBasicString(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('"""', r'\"""');
  }

  static String _escapeBasicString(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\b', r'\b')
        .replaceAll('\t', r'\t')
        .replaceAll('\n', r'\n')
        .replaceAll('\f', r'\f')
        .replaceAll('\r', r'\r');
  }
}
