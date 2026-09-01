import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show formatLocalDateTime;
import 'package:meta/meta.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExitFn, TokenService, WriteLine;

import 'cli_global_options.dart';
import 'config_loader.dart';

export 'cli_global_options.dart' show globalOptionString;

/// Base class for CLI commands that talk to the DartClaw server.
///
/// Centralises the DI constructor (`config`/`apiClient`/`writeLine`/`exitFn`),
/// API-client resolution, and the universal `DartclawApiException` →
/// printed-message + `exit(1)` error policy shared across connected commands.
abstract class ConnectedCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  @protected
  final WriteLine writeLine;
  @protected
  final ExitFn exitFn;

  new({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      writeLine = writeLine ?? stdout.writeln,
      exitFn = exitFn ?? exit;

  /// The injected [DartclawConfig], when one was provided to the constructor.
  ///
  /// Commands with a standalone (server-less) path read this to honour an
  /// injected config before falling back to loading one from disk.
  @protected
  DartclawConfig? get injectedConfig => _config;

  /// The injected API client, when one was provided to the constructor.
  @protected
  DartclawApiClient? get injectedApiClient => _apiClient;

  /// Resolves the API client (injected client/config win, else loaded from global opts).
  @protected
  DartclawApiClient client() =>
      resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);

  /// Runs [body] with a resolved client, mapping [DartclawApiException] to a
  /// printed message + `exit(1)` — the universal connected-command error policy.
  @protected
  Future<void> runConnected(Future<void> Function(DartclawApiClient client) body) async {
    final apiClient = client();
    try {
      await body(apiClient);
    } on DartclawApiException catch (error) {
      writeLine(error.message);
      exitFn(1);
    }
  }

  /// Returns the first positional arg, or throws [UsageException] with
  /// [missingMessage] when absent.
  @protected
  String requirePositionalArg(String missingMessage) {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException(missingMessage, usage);
    }
    return args.first;
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
  return apiClientFromConfig(
    config: effectiveConfig,
    serverOverride: serverOverride(globalResults),
    tokenOverride: globalOptionString(globalResults, 'token'),
  );
}

/// Builds a [DartclawApiClient] from local [config] plus the CLI's overrides.
///
/// The token comes from `--token` when given, is omitted entirely when the
/// gateway runs with `auth_mode: none`, and otherwise falls back to
/// `gateway.token` and then the `gateway_token` file under the data directory.
DartclawApiClient apiClientFromConfig({
  required DartclawConfig config,
  String? serverOverride,
  String? tokenOverride,
  HttpClient Function()? httpClientFactory,
  ApiTransport? transport,
}) {
  final trimmedTokenOverride = tokenOverride?.trim();
  final token = trimmedTokenOverride != null && trimmedTokenOverride.isNotEmpty
      ? trimmedTokenOverride
      : config.gateway.authMode == 'none'
      ? null
      : config.gateway.token ?? TokenService.loadFromFile(config.server.dataDir);
  return DartclawApiClient(
    baseUri: resolveServerUri(config: config, serverOverride: serverOverride),
    token: token,
    httpClientFactory: httpClientFactory,
    transport: transport,
  );
}

/// Resolves the server base URI from [config] and an optional `--server`
/// [serverOverride], which may be a bare port, a host, or a full URL.
Uri resolveServerUri({required DartclawConfig config, String? serverOverride}) {
  final raw = serverOverride?.trim();
  if (raw == null || raw.isEmpty) {
    return Uri(scheme: 'http', host: 'localhost', port: config.server.port);
  }

  if (RegExp(r'^\d+$').hasMatch(raw)) {
    return Uri(scheme: 'http', host: 'localhost', port: int.parse(raw));
  }

  final candidate = raw.contains('://') ? Uri.parse(raw) : Uri.parse('http://$raw');
  final host = candidate.host.isEmpty ? 'localhost' : candidate.host;
  final useConfigPort = !raw.contains('://') && !candidate.hasPort;
  final scheme = candidate.scheme.isEmpty ? 'http' : candidate.scheme;
  final path = candidate.path.isEmpty ? '' : candidate.path;
  if (candidate.hasPort) {
    return Uri(scheme: scheme, host: host, port: candidate.port, path: path);
  }
  if (useConfigPort) {
    return Uri(scheme: scheme, host: host, port: config.server.port, path: path);
  }
  return Uri(scheme: scheme, host: host, path: path);
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

String formatDateTime(Object? value) => formatLocalDateTime(value);

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
