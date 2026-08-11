import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show HttpClientFactory;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Callback for running commands (injectable for tests).
typedef QmdCommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory});

/// Callback for starting QMD processes (injectable for tests).
typedef QmdProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      required Map<String, String> environment,
      required bool includeParentEnvironment,
    });

/// Manages the QMD daemon lifecycle — start, stop, health, indexing.
///
/// QMD is an optional outpost for hybrid memory search. DartClaw manages
/// the daemon subprocess and triggers indexing after memory writes.
class QmdManager {
  static final _log = Logger('QmdManager');
  static const _probeTimeout = Duration(seconds: 5);
  static const _setupTimeout = Duration(seconds: 30);
  static const _updateTimeout = Duration(minutes: 2);
  static const _embedTimeout = Duration(minutes: 30);
  static const _lifecycleTimeout = Duration(seconds: 15);
  static const _queryTimeout = Duration(seconds: 30);
  static const _defaultKillGracePeriod = Duration(seconds: 1);
  static const _maxHttpBodyBytes = 1024 * 1024;
  static const _maxProcessOutputBytes = 1024 * 1024;
  static const _environmentAllowlist = <String>{
    'PATH',
    'HOME',
    'LANG',
    'LANGUAGE',
    'LC_ALL',
    'LC_COLLATE',
    'LC_CTYPE',
    'LC_MESSAGES',
    'LC_MONETARY',
    'LC_NUMERIC',
    'LC_TIME',
    'TZ',
    'USER',
    'SHELL',
    'TERM',
    'TMPDIR',
    'TMP',
    'TEMP',
    'SYSTEMROOT',
    'COMSPEC',
    'PATHEXT',
    'LOCALAPPDATA',
    'APPDATA',
    'USERPROFILE',
  };

  /// Path or name of the `qmd` binary to invoke.
  final String qmdExecutable;

  /// Literal loopback host the QMD daemon listens on.
  final String host;

  /// Port the QMD daemon listens on.
  final int port;

  /// Optional workspace directory passed to the daemon.
  final String? workspaceDir;
  final QmdCommandRunner? _run;
  final QmdProcessStarter _startProcess;
  final HttpClientFactory _httpFactory;
  final Duration _healthRetryDelay;
  final Duration? _commandTimeoutOverride;
  final Duration _killGracePeriod;

  bool _running = false;

  /// Creates a QMD manager bound to the given executable and loopback address.
  ///
  /// Throws [ArgumentError] when [host] is not `localhost`, a `127.0.0.0/8`
  /// address, or IPv6 loopback.
  QmdManager({
    this.qmdExecutable = 'qmd',
    String host = '127.0.0.1',
    this.port = 8181,
    this.workspaceDir,
    QmdCommandRunner? commandRunner,
    QmdProcessStarter? processStarter,
    HttpClientFactory? httpFactory,
    Duration healthRetryDelay = const Duration(milliseconds: 500),
    Duration? commandTimeoutOverride,
    Duration killGracePeriod = _defaultKillGracePeriod,
  }) : host = _validateHost(host),
       _run = commandRunner,
       _startProcess = processStarter ?? Process.start,
       _httpFactory = httpFactory ?? HttpClient.new,
       _healthRetryDelay = healthRetryDelay,
       _commandTimeoutOverride = commandTimeoutOverride,
       _killGracePeriod = killGracePeriod;

  /// Whether the daemon has been started by this manager.
  bool get isRunning => _running;

  /// Base URL composed from [host] and [port].
  String get baseUrl => 'http://${host.contains(':') ? '[$host]' : host}:$port';

  /// Prepares the workspace index and starts the daemon.
  Future<void> activate() async {
    final dir = workspaceDir;
    if (dir == null) throw StateError('QMD activation requires a workspace directory');
    await setupCollection(dir);
    await triggerIndex();
    await start();
  }

  /// Check if QMD binary is installed.
  Future<bool> isAvailable() async {
    try {
      final result = await _runCommand(['--version'], timeout: _probeTimeout);
      if (result.exitCode != 0) return false;
      final match = RegExp(
        r'^qmd (\d+)\.(\d+)\.(\d+)(?:\+[0-9A-Za-z.-]+)?(?: \([0-9A-Fa-f]+\))?$',
      ).firstMatch(result.stdout.toString().trim());
      if (match == null) return false;
      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      final patch = int.parse(match.group(3)!);
      final supported = major == 2 && (minor > 5 || (minor == 5 && patch >= 3));
      if (!supported) _log.warning('Unsupported QMD version ${match.group(0)}; requires 2.5.3 or later 2.x');
      return supported;
    } catch (e) {
      _log.fine('QMD not available: $e');
      return false;
    }
  }

  /// Start the QMD daemon. Waits for health check to succeed.
  Future<void> start() async {
    if (_running) return;

    _log.info('Starting QMD daemon on $host:$port');
    final result = await _runCommand(
      _command(['mcp', '--http', '--daemon', '--port', '$port', '--host', host]),
      workingDirectory: workspaceDir,
      timeout: _lifecycleTimeout,
    );

    if (result.exitCode != 0) {
      throw StateError('QMD daemon failed to start: ${result.stderr}');
    }

    // Wait for health with retries
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(_healthRetryDelay);
      if (await healthCheck()) {
        _running = true;
        _log.info('QMD daemon ready');
        return;
      }
    }
    final stopResult = await _runCommand(
      _command(['mcp', 'stop']),
      workingDirectory: workspaceDir,
      timeout: _lifecycleTimeout,
    );
    _running = false;
    if (stopResult.exitCode != 0) {
      throw StateError('QMD daemon health check failed and cleanup failed: ${stopResult.stderr}');
    }
    throw StateError('QMD daemon started but health check failed');
  }

  /// Stop the QMD daemon.
  ///
  /// Stops the managed daemon through QMD's lifecycle command.
  Future<void> stop() async {
    if (!_running) return;
    final result = await _runCommand(
      _command(['mcp', 'stop']),
      workingDirectory: workspaceDir,
      timeout: _lifecycleTimeout,
    );
    if (result.exitCode != 0) {
      throw StateError('QMD daemon failed to stop: ${result.stderr}');
    }
    _running = false;
    _log.info('QMD daemon stopped');
  }

  /// Check if the daemon is healthy.
  Future<bool> healthCheck() async {
    final client = _httpFactory();
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl/health')).timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      _log.fine('QMD health check failed: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Trigger incremental indexing: `qmd update && qmd embed`.
  Future<void> triggerIndex() async {
    final update = await _runCommand(_command(['update']), workingDirectory: workspaceDir, timeout: _updateTimeout);
    if (update.exitCode != 0) {
      throw StateError('qmd update failed: ${update.stderr}');
    }

    final embed = await _runCommand(_command(['embed']), workingDirectory: workspaceDir, timeout: _embedTimeout);
    if (embed.exitCode != 0) {
      throw StateError('qmd embed failed: ${embed.stderr}');
    }
  }

  /// Ensures the recursive workspace Markdown collection exists.
  Future<void> setupCollection(String workspaceDir) async {
    final existing = await _runCommand(
      _command(['collection', 'show', 'memory']),
      workingDirectory: workspaceDir,
      timeout: _setupTimeout,
    );
    if (existing.exitCode == 0) {
      final output = existing.stdout.toString().replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
      final configuredPath = RegExp(r'^\s*Path:\s+(.+)$', multiLine: true).firstMatch(output)?.group(1)?.trim();
      final configuredPattern = RegExp(r'^\s*Pattern:\s+(.+)$', multiLine: true).firstMatch(output)?.group(1)?.trim();
      final expectedPath = _canonicalPath(workspaceDir);
      if (configuredPath == null || _canonicalPath(configuredPath) != expectedPath || configuredPattern != '**/*.md') {
        throw StateError(
          'qmd collection "memory" must use path $expectedPath and pattern **/*.md. '
          'Run `qmd --index index collection remove memory`, then restart DartClaw to recreate it.',
        );
      }
      return;
    }
    if (!existing.stderr.toString().contains('Collection not found: memory')) {
      throw StateError('qmd collection discovery failed: ${existing.stderr}');
    }

    final result = await _runCommand(
      _command(['collection', 'add', workspaceDir, '--name', 'memory', '--mask', '**/*.md']),
      workingDirectory: workspaceDir,
      timeout: _setupTimeout,
    );
    if (result.exitCode != 0) {
      throw StateError('qmd collection setup failed: ${result.stderr}');
    }
  }

  static String _canonicalPath(String path) {
    final absolute = p.normalize(p.absolute(path));
    try {
      return Directory(absolute).resolveSymbolicLinksSync();
    } on FileSystemException {
      return absolute;
    }
  }

  /// Execute a search query via QMD REST API.
  /// Returns parsed results or throws on failure.
  Future<List<Map<String, dynamic>>> query(String queryText, {String depth = 'standard', int limit = 10}) async {
    final client = _httpFactory();
    final deadline = _commandTimeoutOverride ?? _queryTimeout;
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/query')).timeout(deadline);

      request.headers.set('content-type', 'application/json');
      final types = depth == 'fast' || depth == 'lex' ? const ['lex'] : const ['lex', 'vec'];
      final rerank = depth == 'deep' || depth == 'query';
      request.write(
        jsonEncode({
          'searches': [
            for (final type in types) {'type': type, 'query': queryText},
          ],
          'limit': limit,
          'rerank': rerank,
        }),
      );

      final response = await request.close().timeout(deadline);
      final bodyBytes = await _readLimited(
        response,
        maxBytes: _maxHttpBodyBytes,
        label: 'QMD HTTP response body',
      ).timeout(deadline);
      final body = utf8.decode(bodyBytes);

      if (response.statusCode != 200) {
        throw HttpException('QMD query failed (${response.statusCode}): $body');
      }

      final json = jsonDecode(body);
      if (json is List) {
        return _parseLegacyResults(json);
      }
      if (json is Map<String, dynamic>) {
        final results = json['results'];
        if (results is List) return _parseStructuredResults(results);
      }
      throw const FormatException('Unexpected QMD query response shape');
    } finally {
      client.close(force: true);
    }
  }

  Future<ProcessResult> _runCommand(List<String> arguments, {required Duration timeout, String? workingDirectory}) {
    final deadline = _commandTimeoutOverride ?? timeout;
    final runner = _run;
    if (runner != null) {
      return runner(
        qmdExecutable,
        arguments,
        workingDirectory: workingDirectory,
      ).timeout(deadline, onTimeout: () => throw TimeoutException('qmd ${arguments.join(' ')} timed out', deadline));
    }
    return _runProcess(arguments, workingDirectory: workingDirectory, timeout: deadline);
  }

  Future<ProcessResult> _runProcess(
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
  }) async {
    final stopwatch = Stopwatch()..start();
    final start = _startProcess(
      qmdExecutable,
      arguments,
      workingDirectory: workingDirectory,
      environment: {
        for (final entry in Platform.environment.entries)
          if (_environmentAllowlist.contains(entry.key.toUpperCase())) entry.key: entry.value,
      },
      includeParentEnvironment: false,
    );
    late Process process;
    try {
      process = await start.timeout(timeout);
    } on TimeoutException {
      unawaited(start.then<void>(_terminateProcess, onError: (Object _, StackTrace _) {}));
      throw TimeoutException('qmd ${arguments.join(' ')} timed out', timeout);
    }

    final remaining = timeout - stopwatch.elapsed;
    try {
      final result = await Future.wait<Object>([
        process.exitCode,
        _readLimited(process.stdout, maxBytes: _maxProcessOutputBytes, label: 'QMD process stdout'),
        _readLimited(process.stderr, maxBytes: _maxProcessOutputBytes, label: 'QMD process stderr'),
      ], eagerError: true).timeout(remaining.isNegative ? Duration.zero : remaining);
      return ProcessResult(
        process.pid,
        result[0] as int,
        systemEncoding.decode(result[1] as List<int>),
        systemEncoding.decode(result[2] as List<int>),
      );
    } on TimeoutException {
      await _terminateProcess(process);
      throw TimeoutException('qmd ${arguments.join(' ')} timed out', timeout);
    } catch (_) {
      await _terminateProcess(process);
      rethrow;
    }
  }

  static Future<List<int>> _readLimited(
    Stream<List<int>> stream, {
    required int maxBytes,
    required String label,
  }) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxBytes) {
        throw StateError('$label exceeded the $maxBytes-byte limit');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static List<Map<String, dynamic>> _parseLegacyResults(List<dynamic> values) {
    final results = <Map<String, dynamic>>[];
    for (final value in values) {
      if (value is! Map<String, dynamic> ||
          value['text'] is! String && value['content'] is! String ||
          value['source'] is! String && value['path'] is! String ||
          value['score'] != null && value['score'] is! num ||
          value['category'] != null && value['category'] is! String) {
        throw const FormatException('Unexpected QMD query response shape');
      }
      results.add(value);
    }
    return results;
  }

  static List<Map<String, dynamic>> _parseStructuredResults(List<dynamic> values) {
    final results = <Map<String, dynamic>>[];
    for (final value in values) {
      if (value is! Map<String, dynamic> ||
          value['snippet'] is! String ||
          value['file'] is! String ||
          value['score'] != null && value['score'] is! num ||
          value['category'] != null && value['category'] is! String) {
        throw const FormatException('Unexpected QMD query response shape');
      }
      results.add({...value, 'text': value['snippet'], 'source': value['file']});
    }
    return results;
  }

  Future<void> _terminateProcess(Process process) async {
    process.kill();
    try {
      await process.exitCode.timeout(_killGracePeriod);
    } on TimeoutException {
      process.kill(Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(_killGracePeriod);
      } on TimeoutException {
        _log.warning('Timed-out qmd process ${process.pid} did not exit after force-kill');
      }
    }
  }

  static List<String> _command(List<String> arguments) => ['--index', 'index', ...arguments];

  static String _validateHost(String host) {
    var normalized = host.trim().toLowerCase();
    if (normalized == '[::1]') normalized = '::1';
    if (normalized == 'localhost' || normalized == '::1') return normalized;
    final octets = normalized.split('.');
    final isLoopbackIpv4 =
        octets.length == 4 &&
        octets.first == '127' &&
        octets.every((octet) {
          final value = int.tryParse(octet);
          return value != null && value >= 0 && value <= 255 && value.toString() == octet;
        });
    if (isLoopbackIpv4) return normalized;
    throw ArgumentError.value(host, 'host', 'QMD host must be a literal loopback address');
  }
}
