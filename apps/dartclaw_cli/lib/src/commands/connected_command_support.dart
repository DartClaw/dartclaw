import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show formatLocalDateTime;
import 'package:meta/meta.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExitFn, TokenService, WriteLine;

import 'cli_global_options.dart';
import 'cli_command.dart';
import 'config_loader.dart';

export 'cli_global_options.dart' show globalOptionString;

/// Base class for CLI commands that talk to the DartClaw server.
abstract class ConnectedCommand extends CliCommand {
  final DartclawApiClient? _apiClient;

  new({super.config, DartclawApiClient? apiClient, super.writeLine, super.exitFn, super.stderrLine})
    : _apiClient = apiClient;

  /// The injected API client, when one was provided to the constructor.
  @protected
  DartclawApiClient? get injectedApiClient => _apiClient;

  /// Resolves the API client (injected client/config win, else loaded from global opts).
  @protected
  DartclawApiClient client() =>
      resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: injectedConfig);

  /// Runs [body] with a resolved client, mapping [DartclawApiException] to a
  /// stderr message and the failure-class exit code.
  @protected
  Future<void> runConnected(Future<void> Function(DartclawApiClient client) body) =>
      runCliConnected(client(), body, stderrLine: stderrLine, exitFn: exitFn);
}

bool confirmDestructive({
  required bool yes,
  required bool hasTerminal,
  required String? Function() readLine,
  required String prompt,
  required WriteLine stderrLine,
}) {
  if (yes) return true;
  if (!hasTerminal) {
    stderrLine('Refusing without --yes: stdin is not a terminal.');
    return false;
  }
  stderrLine('$prompt [y/N]');
  final answer = readLine()?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

int connectedExitCode(DartclawApiException error) {
  const transportCodes = {'CONNECTION_REFUSED', 'NETWORK_ERROR', 'TLS_HANDSHAKE_FAILED'};
  final status = error.statusCode;
  if (status == null && transportCodes.contains(error.code)) return 3;
  if (status == 401 || status == 403) return 4;
  if (status != null && status >= 400 && status < 500) return 5;
  if (status != null && status >= 500 && status < 600) return 6;
  return 1;
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
/// [includeToken] disables token resolution entirely for public health probes.
DartclawApiClient apiClientFromConfig({
  required DartclawConfig config,
  String? serverOverride,
  String? tokenOverride,
  HttpClient Function()? httpClientFactory,
  ApiTransport? transport,
  bool includeToken = true,
}) {
  final trimmedTokenOverride = tokenOverride?.trim();
  final token = !includeToken
      ? null
      : trimmedTokenOverride != null && trimmedTokenOverride.isNotEmpty
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

/// Reads the shared health contract; malformed or unresponsive peers are not a server.
Future<Map<String, dynamic>> readServerHealth(DartclawApiClient client) async {
  final health = await client.getObject('/health', expectedStatusCode: 200).timeout(const Duration(seconds: 5));
  if (health['status'] is! String || health['version'] is! String || health['uptime_s'] is! int) {
    throw DartclawApiException('Invalid health response from /health.', code: 'INVALID_RESPONSE');
  }
  return health;
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

Future<void> runCliConnected(
  DartclawApiClient client,
  Future<void> Function(DartclawApiClient) body, {
  required WriteLine stderrLine,
  required ExitFn exitFn,
}) async {
  try {
    await body(client);
  } on DartclawApiException catch (error) {
    stderrLine(error.message);
    exitFn(connectedExitCode(error));
  }
}
