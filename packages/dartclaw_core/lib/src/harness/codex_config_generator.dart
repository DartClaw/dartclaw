/// Generates isolated `config.toml` content for Codex app-server workers.
class CodexConfigGenerator {
  static const String defaultMcpBearerTokenEnvVar = 'DARTCLAW_MCP_TOKEN';

  /// Builds `config.toml` content using only static Codex config-layer fields.
  static String generate({required String developerInstructions, String? mcpServerUrl, String? mcpBearerTokenEnvVar}) {
    final buffer = StringBuffer()
      ..writeln('developer_instructions = """')
      ..writeln(_escapeMultilineBasicString(developerInstructions))
      ..writeln('"""');

    final trimmedMcpServerUrl = mcpServerUrl?.trim();
    if (trimmedMcpServerUrl != null && trimmedMcpServerUrl.isNotEmpty) {
      final bearerTokenEnvVar = (mcpBearerTokenEnvVar?.trim().isNotEmpty ?? false)
          ? mcpBearerTokenEnvVar!.trim()
          : defaultMcpBearerTokenEnvVar;

      buffer
        ..writeln()
        ..writeln('[mcp_servers.dartclaw]')
        ..writeln('url = "${_escapeBasicString(trimmedMcpServerUrl)}"')
        ..writeln('bearer_token_env_var = "${_escapeBasicString(bearerTokenEnvVar)}"');
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
