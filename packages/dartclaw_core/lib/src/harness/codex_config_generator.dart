import 'dart:convert';

/// The Codex `model_providers` key DartClaw's host gateway is published under.
const codexGatewayProviderId = 'dartclaw';

/// One `[plugins.*]` table of a Codex `config.toml`, copied verbatim.
///
/// [header] is the table's own header line, trimmed — the identity a mirror
/// records so it can later tell a table it wrote from one an operator installed
/// into the target home directly. [text] is the whole table, header included,
/// without trailing blank lines.
class CodexPluginTable {
  const new({required this.header, required this.text});

  final String header;
  final String text;

  @override
  bool operator ==(Object other) => other is CodexPluginTable && other.header == header && other.text == text;

  @override
  int get hashCode => Object.hash(header, text);
}

/// A Codex `config.toml` split into its `[plugins.*]` tables and everything else.
class CodexTomlSplit {
  const new({required this.pluginTables, required this.remainder});

  /// The `[plugins.*]` tables in document order.
  final List<CodexPluginTable> pluginTables;

  /// The document with every `[plugins.*]` table removed and trailing blank
  /// lines dropped.
  final String remainder;
}

/// Generates isolated `config.toml` content for Codex app-server workers.
class CodexConfigGenerator {
  static const String defaultMcpBearerTokenEnvVar = 'DARTCLAW_MCP_TOKEN';

  /// Splits [configToml] into its `[plugins.*]` tables and the rest, or returns
  /// `null` when the document uses a construct outside the supported subset.
  ///
  /// A plugin is enabled by a table in the home's own `config.toml`, so a
  /// generated home enables nothing unless those tables are carried into it.
  /// Table bodies are copied verbatim: this decides which tables to keep, never
  /// what their values mean.
  ///
  /// ## Supported subset
  ///
  /// This is a splitter, not a TOML parser, and it is deliberately narrow. It
  /// understands standard table headers on their own line; basic (`"`), literal
  /// (`'`) and both multiline (`"""`, `'''`) strings, including backslash
  /// escapes and an escaped `"""` inside a multiline basic string; `#`
  /// comments; and arrays spanning several lines.
  ///
  /// ## Refused, fail-closed (returns `null`)
  ///
  /// Anything it cannot place with certainty, because splicing a
  /// half-understood document into a live Codex home would silently enable or
  /// disable plugins:
  ///
  /// - a bare `[plugins]` table, whose keys are plugin configuration no
  ///   `[plugins.<name>]` table owns;
  /// - a `[[plugins…]]` array of tables;
  /// - a top-level `plugins = { … }` inline table or a `plugins.<…> = …` dotted
  ///   key, which configure plugins without a table header;
  /// - an unterminated string or array, on a line or at end of document.
  static CodexTomlSplit? splitPluginTables(String configToml) {
    final tables = <CodexPluginTable>[];
    final remainder = <String>[];
    var current = <String>[];
    String? currentHeader;
    var atTopLevel = true;
    var arrayDepth = 0;
    String? openDelimiter;

    void closeTable() {
      final header = currentHeader;
      if (header == null) return;
      while (current.isNotEmpty && current.last.trim().isEmpty) {
        current.removeLast();
      }
      tables.add(CodexPluginTable(header: header, text: current.join('\n')));
      current = <String>[];
      currentHeader = null;
    }

    void emit(String line) => (currentHeader == null ? remainder : current).add(line.trimRight());

    for (final line in const LineSplitter().convert(configToml)) {
      final scan = _scanLine(line, openDelimiter);
      if (scan == null) return null;
      openDelimiter = scan.openDelimiter;
      final code = scan.code.trim();

      if (arrayDepth > 0) {
        emit(line);
        arrayDepth += _bracketDelta(scan.code);
        if (arrayDepth < 0) return null;
        continue;
      }

      if (code.startsWith('[')) {
        if (_barePluginsTable.hasMatch(code) || _pluginsArrayOfTables.hasMatch(code)) return null;
        closeTable();
        if (_pluginTable.hasMatch(code)) {
          currentHeader = line.trim();
          current.add(line.trimRight());
        } else {
          remainder.add(line.trimRight());
        }
        atTopLevel = false;
        continue;
      }

      if (atTopLevel && _topLevelPluginsKey.hasMatch(code)) return null;
      emit(line);
      arrayDepth += _bracketDelta(scan.code);
      if (arrayDepth < 0) return null;
    }

    if (openDelimiter != null || arrayDepth != 0) return null;
    closeTable();

    while (remainder.isNotEmpty && remainder.last.trim().isEmpty) {
      remainder.removeLast();
    }
    return CodexTomlSplit(pluginTables: tables, remainder: remainder.join('\n'));
  }

  /// Composes [base] with [tables] — the one way a `config.toml` carrying
  /// plugin tables is assembled, so every writer produces byte-identical output
  /// for the same inputs.
  static String withPluginTables(String base, Iterable<String> tables) {
    final trimmedBase = base.trimRight();
    final body = tables.map((table) => table.trim()).where((table) => table.isNotEmpty).join('\n\n');
    if (body.isEmpty) return trimmedBase.isEmpty ? '' : '$trimmedBase\n';
    if (trimmedBase.isEmpty) return '$body\n';
    return '$trimmedBase\n\n$body\n';
  }

  static final RegExp _pluginTable = RegExp(r'^\[plugins\.');
  static final RegExp _barePluginsTable = RegExp(r'^\[\s*plugins\s*\]');
  static final RegExp _pluginsArrayOfTables = RegExp(r'^\[\[\s*plugins[.\]\s]');
  static final RegExp _topLevelPluginsKey = RegExp(r'^plugins\s*[.=]');

  static int _bracketDelta(String code) => '['.allMatches(code).length - ']'.allMatches(code).length;

  /// Strips strings and comments from [line] so brackets and keys can be read as
  /// structure. [open] is the multiline delimiter a previous line left open.
  static _LineScan? _scanLine(String line, String? open) {
    final code = StringBuffer();
    var index = 0;

    if (open != null) {
      final close = _findMultilineClose(line, open, 0);
      if (close < 0) return _LineScan('', open);
      index = close + 3;
    }

    while (index < line.length) {
      final char = line[index];
      if (char == '#') break;
      if (line.startsWith('"""', index) || line.startsWith("'''", index)) {
        final delimiter = line.substring(index, index + 3);
        final close = _findMultilineClose(line, delimiter, index + 3);
        if (close < 0) return _LineScan(code.toString(), delimiter);
        index = close + 3;
        continue;
      }
      if (char == '"' || char == "'") {
        final end = _endOfString(line, index, char);
        if (end < 0) return null;
        index = end + 1;
        continue;
      }
      code.write(char);
      index++;
    }
    return _LineScan(code.toString(), null);
  }

  /// Index of [delimiter] at or after [from], skipping a `"""` whose first quote
  /// an odd run of backslashes escapes.
  static int _findMultilineClose(String line, String delimiter, int from) {
    var at = line.indexOf(delimiter, from);
    while (at >= 0) {
      if (delimiter == "'''" || !_isEscaped(line, at)) return at;
      at = line.indexOf(delimiter, at + 1);
    }
    return -1;
  }

  static int _endOfString(String line, int start, String quote) {
    for (var index = start + 1; index < line.length; index++) {
      if (line[index] != quote) continue;
      if (quote == '"' && _isEscaped(line, index)) continue;
      return index;
    }
    return -1;
  }

  static bool _isEscaped(String line, int index) {
    var backslashes = 0;
    for (var at = index - 1; at >= 0 && line[at] == r'\'; at--) {
      backslashes++;
    }
    return backslashes.isOdd;
  }

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
  ///
  /// Plugin tables are never generated here; [withPluginTables] splices them.
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

class _LineScan {
  const new(this.code, this.openDelimiter);

  final String code;
  final String? openDelimiter;
}
