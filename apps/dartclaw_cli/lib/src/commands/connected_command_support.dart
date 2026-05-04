import 'dart:convert';

import 'package:args/args.dart' show ArgResults;
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../dartclaw_api_client.dart';
import 'config_loader.dart';
import 'serve_command.dart' show WriteLine;

String? globalOptionString(ArgResults? results, String name) {
  if (results == null) {
    return null;
  }
  try {
    return results[name] as String?;
  } on ArgumentError {
    return null;
  }
}

DartclawApiClient resolveCliApiClient({
  required ArgResults? globalResults,
  DartclawApiClient? apiClient,
  DartclawConfig? config,
}) {
  if (apiClient != null) {
    return apiClient;
  }
  final effectiveConfig = config ?? loadCliConfig(configPath: globalOptionString(globalResults, 'config'));
  return DartclawApiClient.fromConfig(
    config: effectiveConfig,
    serverOverride: globalOptionString(globalResults, 'server'),
    tokenOverride: globalOptionString(globalResults, 'token'),
  );
}

void writePrettyJson(WriteLine writeLine, Object? value) {
  writeLine(const JsonEncoder.withIndent('  ').convert(value));
}

String truncate(String value, int width) {
  if (value.length <= width) {
    return value;
  }
  return '${value.substring(0, width - 3)}...';
}

String formatDateTime(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) {
    return '—';
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    return raw;
  }
  return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
      '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
}

String formatNumber(int value) {
  final raw = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < raw.length; index++) {
    if (index > 0 && (raw.length - index) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(raw[index]);
  }
  return buffer.toString();
}

Object? parseCliValue(String raw) {
  final trimmed = raw.trim();
  if (trimmed == 'null') {
    return null;
  }
  if (trimmed == 'true') {
    return true;
  }
  if (trimmed == 'false') {
    return false;
  }
  final intValue = int.tryParse(trimmed);
  if (intValue != null) {
    return intValue;
  }
  final doubleValue = double.tryParse(trimmed);
  if (doubleValue != null) {
    return doubleValue;
  }
  try {
    return jsonDecode(trimmed);
  } on FormatException {
    return raw;
  }
}

({bool exists, Object? value}) lookupPath(Map<String, dynamic> root, String path) {
  Object? current = root;
  for (final segment in path.split('.')) {
    if (current is! Map || !current.containsKey(segment)) {
      return (exists: false, value: null);
    }
    current = current[segment];
  }
  return (exists: true, value: current);
}
