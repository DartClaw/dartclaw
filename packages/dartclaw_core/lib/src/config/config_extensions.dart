part of 'dartclaw_config.dart';

final Map<String, Object Function(Map<String, dynamic>, List<String>)> _extensionParsers = {};

void _registerExtensionParser(String name, Object Function(Map<String, dynamic> yaml, List<String> warns) parser) {
  if (_knownKeys.contains(name)) {
    throw ArgumentError('Cannot register extension parser for built-in config key: "$name"');
  }
  _extensionParsers[name] = parser;
}

void _clearExtensionParsers() => _extensionParsers.clear();

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
