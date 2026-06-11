part of 'dartclaw_config.dart';

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
    }

    entries[providerId] = ProviderEntry(
      executable: expandHome(executableRaw.trim(), env: env),
      poolSize: poolSize,
      options: options,
    );
  }

  return ProvidersConfig(entries: entries);
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
