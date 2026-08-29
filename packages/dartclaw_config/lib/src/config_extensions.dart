part of 'dartclaw_config.dart';

final Map<String, Object Function(Map<String, dynamic>, List<String>)> _extensionParsers = {};

void _registerExtensionParser(String name, Object Function(Map<String, dynamic> yaml, List<String> warns) parser) {
  if (_knownKeys.contains(name)) {
    throw ArgumentError('Cannot register extension parser for built-in config key: "$name"');
  }
  _extensionParsers[name] = parser;
}

void _clearExtensionParsers() => _extensionParsers.clear();

Set<String> _registeredExtensionKeys() => Set<String>.unmodifiable(_extensionParsers.keys);

Set<String> _knownConfigKeys() => Set<String>.unmodifiable(_knownKeys);

Map<String, Object?> _parseExtensions(Map<String, dynamic> yaml, List<String> warns) {
  final extensions = <String, Object?>{};
  for (final key in yaml.keys) {
    if (_knownKeys.contains(key)) continue;
    final rawValue = yaml[key];
    final parser = _extensionParsers[key];
    if (parser != null) {
      if (rawValue is Map || rawValue == null) {
        final rawMap = rawValue is Map ? Map<String, dynamic>.from(rawValue) : <String, dynamic>{};
        try {
          extensions[key] = parser(rawMap, warns);
        } catch (e) {
          warns.add('Error parsing extension "$key": $e — storing as raw data');
          extensions[key] = rawMap;
        }
      } else {
        warns.add(
          'Extension "$key" expected a map but got '
          '${rawValue.runtimeType} — storing raw value',
        );
        extensions[key] = rawValue;
      }
    } else {
      extensions[key] = rawValue is Map ? Map<String, dynamic>.from(rawValue) : rawValue;
    }
  }
  return extensions;
}

/// Registered snapshot source for credentials DartClaw stores on disk.
///
/// A closure, not a path: this package reads no credential file, and the store
/// it answers from is opened by whichever bootstrap registered it.
Map<String, CredentialEntry> Function(String credentialsDir)? _storedCredentialProvider;

void _registerStoredCredentialProvider(Map<String, CredentialEntry> Function(String credentialsDir) provider) {
  _storedCredentialProvider = provider;
}

void _clearStoredCredentialProvider() => _storedCredentialProvider = null;

/// The stored snapshot for a load rooted at [credentialsDir].
///
/// An unusable store is no store: the provider owns the absent-not-throw
/// contract, but a bootstrap that lets something escape must not take the whole
/// config down with it — every other credential in the file would go with it.
Map<String, CredentialEntry> _storedCredentials(String credentialsDir, List<String> warns) {
  final provider = _storedCredentialProvider;
  if (provider == null) return const {};
  try {
    return provider(credentialsDir);
  } catch (error) {
    // The type only: these paths hold credentials, and an error built from one
    // (`ArgumentError.value` embeds the value it rejected) must not be echoed
    // into a warning that reaches the logs.
    warns.add('Could not read stored credentials from "$credentialsDir" (${error.runtimeType}) — continuing without');
    return const {};
  }
}
