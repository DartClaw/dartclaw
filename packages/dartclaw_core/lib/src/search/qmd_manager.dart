import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Callback for running commands (injectable for tests).
typedef QmdCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

/// Callback for creating HTTP clients (injectable for tests).
typedef HttpClientFactory = HttpClient Function();

/// Manages the QMD daemon lifecycle — start, stop, health, indexing.
///
/// QMD is an optional outpost for hybrid memory search. DartClaw manages
/// the daemon subprocess and triggers indexing after memory writes.
class QmdManager {
  static final _log = Logger('QmdManager');

  final String qmdExecutable;
  final String host;
  final int port;
  final String? workspaceDir;
  final QmdCommandRunner _run;
  final HttpClientFactory _httpFactory;

  bool _running = false;

  QmdManager({
    this.qmdExecutable = 'qmd',
    this.host = '127.0.0.1',
    this.port = 8181,
    this.workspaceDir,
    QmdCommandRunner? commandRunner,
    HttpClientFactory? httpFactory,
  })  : _run = commandRunner ?? _defaultRunner,
        _httpFactory = httpFactory ?? HttpClient.new;

  bool get isRunning => _running;

  String get baseUrl => 'http://$host:$port';

  /// Check if QMD binary is installed.
  Future<bool> isAvailable() async {
    try {
      final result = await _run(qmdExecutable, ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Start the QMD daemon. Waits for health check to succeed.
  Future<void> start() async {
    if (_running) return;

    _log.info('Starting QMD daemon on $host:$port');
    final result = await _run(
      qmdExecutable,
      ['mcp', '--http', '--daemon', '--port', '$port'],
      workingDirectory: workspaceDir,
    );

    if (result.exitCode != 0) {
      throw StateError('QMD daemon failed to start: ${result.stderr}');
    }

    // Wait for health with retries
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await healthCheck()) {
        _running = true;
        _log.info('QMD daemon ready');
        return;
      }
    }
    throw StateError('QMD daemon started but health check failed after 5s');
  }

  /// Stop the QMD daemon.
  ///
  /// Attempts graceful shutdown via HTTP `/shutdown`, then falls back to
  /// `daemon stop` command.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    // Try graceful shutdown via HTTP
    try {
      final client = _httpFactory();
      try {
        final request = await client
            .postUrl(Uri.parse('$baseUrl/shutdown'))
            .timeout(const Duration(seconds: 3));
        await request.close().timeout(const Duration(seconds: 3));
      } finally {
        client.close(force: true);
      }
      _log.info('QMD daemon stopped via HTTP');
      return;
    } catch (_) {
      // Shutdown endpoint may not exist — fall through
    }

    // Fallback: try daemon stop command
    try {
      await _run(qmdExecutable, ['daemon', 'stop'], workingDirectory: workspaceDir);
      _log.info('QMD daemon stopped via command');
      return;
    } catch (_) {
      // Command may not exist — fall through
    }

    _log.warning('QMD daemon stop: neither HTTP shutdown nor daemon stop succeeded');
  }

  /// Check if the daemon is healthy.
  Future<bool> healthCheck() async {
    final client = _httpFactory();
    try {
      final request = await client
          .getUrl(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Trigger incremental indexing: `qmd update && qmd embed`.
  Future<void> triggerIndex() async {
    final update = await _run(qmdExecutable, ['update'], workingDirectory: workspaceDir);
    if (update.exitCode != 0) {
      _log.warning('qmd update failed: ${update.stderr}');
      return;
    }

    final embed = await _run(qmdExecutable, ['embed'], workingDirectory: workspaceDir);
    if (embed.exitCode != 0) {
      _log.warning('qmd embed failed: ${embed.stderr}');
    }
  }

  /// Setup collection for workspace directory.
  Future<void> setupCollection(String workspaceDir) async {
    final result = await _run(
      qmdExecutable,
      ['collection', 'add', workspaceDir, '--name', 'memory', '--mask', '*.md'],
    );
    if (result.exitCode != 0) {
      _log.warning('qmd collection setup failed: ${result.stderr}');
    }
  }

  /// Execute a search query via QMD REST API.
  /// Returns parsed results or throws on failure.
  Future<List<Map<String, dynamic>>> query(
    String queryText, {
    String depth = 'standard',
    int limit = 10,
  }) async {
    final client = _httpFactory();
    try {
      final request = await client
          .postUrl(Uri.parse('$baseUrl/query'))
          .timeout(const Duration(seconds: 30));

      request.headers.set('content-type', 'application/json');
      request.write(jsonEncode({
        'query': queryText,
        'depth': depth,
        'limit': limit,
      }));

      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw HttpException('QMD query failed (${response.statusCode}): $body');
      }

      final json = jsonDecode(body);
      if (json is List) {
        return json.cast<Map<String, dynamic>>();
      }
      if (json is Map && json['results'] is List) {
        return (json['results'] as List).cast<Map<String, dynamic>>();
      }
      return [];
    } finally {
      client.close(force: true);
    }
  }

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    return Process.run(executable, arguments, workingDirectory: workingDirectory);
  }
}
