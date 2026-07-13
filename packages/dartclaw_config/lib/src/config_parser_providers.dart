part of 'dartclaw_config.dart';

final _mcpServersLog = Logger('McpServersConfig');

SearchConfig _parseSearch(
  Map<String, dynamic> yaml,
  Map<String, String> env,
  SearchConfig defaults,
  List<String> warns,
) {
  final providers = <String, SearchProviderEntry>{};
  var backend = defaults.backend;
  var qmdHost = defaults.qmdHost;
  var qmdPort = defaults.qmdPort;
  var defaultDepth = defaults.defaultDepth;

  final searchMap = _sectionMap('search', yaml, warns);
  if (searchMap != null) {
    final backendVal = readString('backend', searchMap, warns);
    if (backendVal != null) {
      if (backendVal == 'fts5' || backendVal == 'qmd') {
        backend = backendVal;
      } else {
        warns.add('Invalid search.backend: "$backendVal" — using default');
      }
    }
    final qmdMap = readMap('qmd', searchMap, warns);
    if (qmdMap != null) {
      qmdHost = readString('host', qmdMap, warns, defaultValue: qmdHost) ?? qmdHost;
      qmdPort = readInt('port', qmdMap, warns, defaultValue: defaults.qmdPort) ?? defaults.qmdPort;
    }
    final depth = readString('default_depth', searchMap, warns);
    if (depth != null) defaultDepth = depth;

    final providersMap = readMap('providers', searchMap, warns);
    if (providersMap != null) {
      for (final entry in providersMap.entries) {
        final name = entry.key.toString();
        final value = entry.value;
        if (value is! Map) {
          // reason: dynamic key interpolation — per-provider name can't use readX helpers
          warns.add('Invalid type for search.providers.$name: "${value.runtimeType}" — skipping');
          continue;
        }
        final enabled = value['enabled'];
        if (enabled is! bool) {
          warns.add('search.providers.$name missing or invalid "enabled" — skipping');
          continue;
        }
        final rawKey = value['api_key'];
        if (rawKey == null || rawKey is! String || rawKey.isEmpty) {
          warns.add('search.providers.$name missing "api_key" — skipping');
          continue;
        }
        final apiKey = envSubstitute(rawKey, env: env);
        providers[name] = SearchProviderEntry(enabled: enabled, apiKey: apiKey);
      }
    }
  }

  return SearchConfig(
    backend: backend,
    qmdHost: qmdHost,
    qmdPort: qmdPort,
    defaultDepth: defaultDepth,
    providers: providers,
  );
}

ProvidersConfig _parseProviders(
  Map<String, dynamic> yaml,
  Map<String, String> env,
  ProvidersConfig defaults,
  List<String> warns,
) {
  final providersRaw = readMap('providers', yaml, warns);
  if (providersRaw == null) return defaults;

  final entries = <String, ProviderEntry>{};
  for (final entry in providersRaw.entries) {
    final providerId = entry.key.toString();
    final value = entry.value;
    if (value is! Map) {
      // reason: dynamic key interpolation — per-provider id can't use readX helpers
      warns.add('Invalid type for providers.$providerId: "${value.runtimeType}" — skipping');
      continue;
    }

    final providerMap = Map<String, dynamic>.from(value);
    final executableRaw = providerMap['executable'];
    if (executableRaw is! String || executableRaw.trim().isEmpty) {
      warns.add('providers.$providerId missing "executable" — skipping');
      continue;
    }

    final poolSizeRaw = providerMap['pool_size'];
    // reason: dynamic key interpolation — per-provider pool_size can't use readX helpers
    if (poolSizeRaw != null && poolSizeRaw is! int) {
      warns.add('Invalid type for providers.$providerId.pool_size: "${poolSizeRaw.runtimeType}" — using default');
    }
    var poolSize = poolSizeRaw is int ? poolSizeRaw : 0;
    if (poolSize < 0) {
      warns.add('Invalid value for providers.$providerId.pool_size: "$poolSize" — using default');
      poolSize = 0;
    }

    final options = Map<String, dynamic>.from(providerMap)
      ..remove('executable')
      ..remove('pool_size');
    if (ProviderIdentity.family(providerId) == ProviderIdentity.claude) {
      final inheritUserSettingsRaw = providerMap[ClaudeProviderOptions.inheritUserSettingsKey];
      if (inheritUserSettingsRaw != null && inheritUserSettingsRaw is! bool) {
        warns.add(
          'Invalid type for providers.$providerId.inherit_user_settings: '
          '"${inheritUserSettingsRaw.runtimeType}" — using default',
        );
      }
      options[ClaudeProviderOptions.inheritUserSettingsKey] = ClaudeProviderOptions.normalizeInheritUserSettings(
        inheritUserSettingsRaw,
      );
      _validateClaudeApproval(providerId, options, warns);
      _validateClaudeSandbox(providerId, options, warns);
    }

    entries[providerId] = ProviderEntry(
      executable: expandHome(executableRaw.trim(), env: env),
      poolSize: poolSize,
      options: options,
    );
  }

  return ProvidersConfig(entries: entries);
}

/// Validates the Claude `approval` provider option in place: an unrecognised
/// value warns and is dropped so the run keeps the current allow-list default.
/// A valid `approval: never` emits a loud security warning — on the one-shot CLI
/// path it removes all tool gating (no hooks, no allow-list), so off-container it
/// leaves no containment at all.
void _validateClaudeApproval(String providerId, Map<String, dynamic> options, List<String> warns) {
  final raw = options[ClaudeProviderOptions.approvalKey];
  if (raw == null) return;
  if (raw is! String || !ClaudeProviderOptions.approvalValues.contains(raw)) {
    warns.add(
      'Invalid value for providers.$providerId.approval: "$raw" — ignoring '
      '(accepted: ${ClaudeProviderOptions.approvalValues.join(', ')})',
    );
    options.remove(ClaudeProviderOptions.approvalKey);
    return;
  }
  if (raw == 'never') {
    addConfigAdvisory(
      warns,
      'providers.$providerId.approval is "never" — this opts Claude one-shot runs into FULL ACCESS: '
      'no tool prompt gating and no static allow-list. The one-shot path has no hooks, so off-container '
      '(host path) this grants unrestricted filesystem access. Use only for fully trusted runs.',
    );
  }
}

/// Validates the Claude `sandbox` provider option in place. A map value is a raw
/// native Claude settings block and passes through untouched; a string value
/// must be one of the coarse parity values, else it warns and is dropped. Other
/// types warn and are dropped.
void _validateClaudeSandbox(String providerId, Map<String, dynamic> options, List<String> warns) {
  final raw = options[ClaudeProviderOptions.sandboxKey];
  if (raw == null || raw is Map) return;
  if (raw is! String || !ClaudeProviderOptions.sandboxValues.contains(raw)) {
    warns.add(
      'Invalid value for providers.$providerId.sandbox: "$raw" — ignoring '
      '(accepted: ${ClaudeProviderOptions.sandboxValues.join(', ')}, or a raw settings map)',
    );
    options.remove(ClaudeProviderOptions.sandboxKey);
  }
}

McpServersConfig _parseMcpServers(
  Map<String, dynamic> yaml,
  CredentialsConfig credentials,
  McpServersConfig defaults,
  List<String> warns,
) {
  final raw = yaml['mcp_servers'];
  if (raw == null) return defaults;
  if (raw is! Map) {
    throw FormatException('mcp_servers must be a map of server entries.');
  }

  if (raw is YamlMap) {
    _rejectDuplicateMcpServerNames(raw);
  }

  final entries = <String, McpServerEntry>{};
  for (final entry in raw.entries) {
    final serverName = entry.key.toString();
    final value = entry.value;
    if (value is! Map) {
      throw FormatException('mcp_servers.$serverName must be a map entry.');
    }

    final serverMap = Map<String, dynamic>.from(value);
    final command = _readOptionalMcpString(serverMap, 'command', serverName);
    final url = _readOptionalMcpString(serverMap, 'url', serverName);
    if (url != null) {
      _validateMcpServerUrl(serverName, url);
    }
    if ((command == null) == (url == null)) {
      throw FormatException('mcp_servers.$serverName must declare exactly one transport: command or url.');
    }

    final networkClassRaw = serverMap['network_class'];
    if (networkClassRaw is! String || networkClassRaw.trim().isEmpty) {
      throw FormatException(
        'mcp_servers.$serverName missing network_class '
        '(accepted: ${McpNetworkClass.knownValues.join(', ')}).',
      );
    }
    final networkClass = McpNetworkClass.fromYaml(networkClassRaw);
    if (networkClass == null) {
      throw FormatException(
        'mcp_servers.$serverName has unknown network_class "$networkClassRaw" '
        '(accepted: ${McpNetworkClass.knownValues.join(', ')}).',
      );
    }

    final enabledRaw = serverMap['enabled'];
    if (enabledRaw != null && enabledRaw is! bool) {
      throw FormatException('mcp_servers.$serverName enabled must be a boolean when present.');
    }

    final credential = _readOptionalMcpString(serverMap, 'credential', serverName);
    final rateLimit = _parseMcpServerRateLimit(serverName, serverMap['rate_limit']);
    final tokenBudget = _parseMcpServerTokenBudget(serverName, serverMap['token_budget']);
    final allowTools = _parseMcpServerToolList(serverName, 'allow_tools', serverMap['allow_tools']);
    final surfaceTools = _parseMcpServerToolList(serverName, 'surface_tools', serverMap['surface_tools']);
    var enabled = enabledRaw is bool ? enabledRaw : true;
    if (enabled && (credential == null || credentials[credential]?.isPresent != true)) {
      enabled = false;
      final message = credential == null
          ? 'mcp_servers.$serverName has no credential reference — disabling server'
          : 'mcp_servers.$serverName credential "$credential" is unresolved — disabling server';
      warns.add(message);
      _mcpServersLog.warning(message);
    }

    entries[serverName] = McpServerEntry(
      command: command,
      url: url,
      enabled: enabled,
      networkClass: networkClass,
      credential: credential,
      rateLimit: rateLimit,
      tokenBudget: tokenBudget,
      allowTools: allowTools,
      surfaceTools: surfaceTools,
    );
  }

  return McpServersConfig(entries: entries);
}

McpServerRateLimit _parseMcpServerRateLimit(String serverName, Object? raw) {
  if (raw == null) return const McpServerRateLimit();
  if (raw is! Map) {
    throw FormatException('mcp_servers.$serverName.rate_limit must be a map when present.');
  }
  final map = Map<String, dynamic>.from(raw);
  final calls = _readNonNegativeMcpInt(serverName, map, 'rate_limit', 'calls');
  final windowSeconds = _readNonNegativeMcpInt(serverName, map, 'rate_limit', 'window_seconds', defaultValue: 60);
  return McpServerRateLimit(
    calls: calls,
    window: Duration(seconds: windowSeconds),
  );
}

McpServerTokenBudget _parseMcpServerTokenBudget(String serverName, Object? raw) {
  if (raw == null) return const McpServerTokenBudget();
  if (raw is! Map) {
    throw FormatException('mcp_servers.$serverName.token_budget must be a map when present.');
  }
  final map = Map<String, dynamic>.from(raw);
  final tokens = _readNonNegativeMcpInt(serverName, map, 'token_budget', 'tokens');
  final windowSeconds = _readNonNegativeMcpInt(serverName, map, 'token_budget', 'window_seconds', defaultValue: 60);
  return McpServerTokenBudget(
    tokens: tokens,
    window: Duration(seconds: windowSeconds),
  );
}

List<String> _parseMcpServerToolList(String serverName, String key, Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw FormatException('mcp_servers.$serverName.$key must be a list of tool names when present.');
  }
  final tools = <String>[];
  for (final value in raw) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('mcp_servers.$serverName.$key must contain only non-empty tool names.');
    }
    tools.add(value.trim());
  }
  return List.unmodifiable(tools);
}

int _readNonNegativeMcpInt(
  String serverName,
  Map<String, dynamic> map,
  String section,
  String key, {
  int defaultValue = 0,
}) {
  final raw = map[key];
  if (raw == null) return defaultValue;
  if (raw is! int) {
    throw FormatException('mcp_servers.$serverName.$section.$key must be a non-negative integer.');
  }
  if (raw < 0) {
    throw FormatException('mcp_servers.$serverName.$section.$key must be non-negative.');
  }
  return raw;
}

CredentialsConfig _parseCredentials(
  Map<String, dynamic> yaml,
  Map<String, String> env,
  CredentialsConfig defaults,
  List<String> warns,
) {
  final credentialsRaw = readMap('credentials', yaml, warns);
  if (credentialsRaw == null) return defaults;

  final entries = <String, CredentialEntry>{};
  for (final entry in credentialsRaw.entries) {
    final credentialName = entry.key.toString();
    final value = entry.value;
    if (value is! Map) {
      // reason: dynamic key interpolation — per-credential name can't use readX helpers
      warns.add('Invalid type for credentials.$credentialName: "${value.runtimeType}" — skipping');
      continue;
    }

    final credentialMap = Map<String, dynamic>.from(value);
    final credentialTypeRaw = credentialMap['type'];
    final credentialType = switch (credentialTypeRaw) {
      null => null,
      'api-key' || 'apiKey' => CredentialType.apiKey,
      'github-token' || 'githubToken' => CredentialType.githubToken,
      _ => null,
    };

    if (credentialTypeRaw != null && credentialType == null) {
      warns.add('credentials.$credentialName has unknown "type" "$credentialTypeRaw" — skipping');
      continue;
    }

    switch (credentialType ?? CredentialType.apiKey) {
      case CredentialType.apiKey:
        final apiKeyRaw = credentialMap['api_key'];
        if (apiKeyRaw is! String) {
          warns.add('credentials.$credentialName missing "api_key" — skipping');
          continue;
        }
        entries[credentialName] = CredentialEntry(
          apiKey: envSubstitute(apiKeyRaw, env: env),
          envVars: envReferences(apiKeyRaw),
        );

      case CredentialType.githubToken:
        final tokenRaw = credentialMap['token'];
        if (tokenRaw is! String) {
          warns.add('credentials.$credentialName missing "token" — skipping');
          continue;
        }
        final repositoryRaw = credentialMap['repository'];
        final repository = repositoryRaw is String ? repositoryRaw.trim() : null;
        entries[credentialName] = CredentialEntry.githubToken(
          token: envSubstitute(tokenRaw, env: env),
          repository: repository == null || repository.isEmpty ? null : repository,
          envVars: envReferences(tokenRaw),
        );
    }
  }

  return CredentialsConfig(entries: entries);
}

String? _readOptionalMcpString(Map<String, dynamic> serverMap, String key, String serverName) {
  final raw = serverMap[key];
  if (raw == null) return null;
  if (raw is! String) {
    throw FormatException('mcp_servers.$serverName $key must be a string when present.');
  }
  final value = raw.trim();
  return value.isEmpty ? null : value;
}

void _validateMcpServerUrl(String serverName, String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException(
      'mcp_servers.$serverName url must be an absolute http or https URL with a host and no userinfo, query, or fragment.',
    );
  }
}

void _rejectDuplicateMcpServerNames(YamlMap raw) {
  final seen = <String>{};
  for (final keyNode in raw.nodes.keys.cast<YamlNode>()) {
    final name = keyNode.value.toString();
    if (!seen.add(name)) {
      throw FormatException('mcp_servers contains duplicate server name "$name".');
    }
  }
}
