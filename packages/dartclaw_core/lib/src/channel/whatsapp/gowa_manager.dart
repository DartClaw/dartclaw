import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';

import '../../harness/claude_code_harness.dart' show ProcessFactory, DelayFactory;

/// Manages the GOWA (Go WhatsApp) sidecar binary as a subprocess.
///
/// Follows the ClaudeCodeHarness lifecycle pattern: spawn, health check,
/// crash recovery with exponential backoff.
class GowaManager {
  static final _log = Logger('GowaManager');

  final String executable;
  final String host;
  final int port;
  final String? dataDir;
  final int maxRestartAttempts;
  final ProcessFactory _processFactory;
  final DelayFactory _delay;

  Process? _process;
  int _generation = 0;
  int _restartCount = 0;
  bool _stopped = false;

  GowaManager({
    required this.executable,
    this.host = '127.0.0.1',
    this.port = 3080,
    this.dataDir,
    this.maxRestartAttempts = 5,
    ProcessFactory? processFactory,
    DelayFactory? delay,
  }) : _processFactory = processFactory ?? Process.start,
       _delay = delay ?? Future.delayed;

  bool get isRunning => _process != null && !_stopped;

  String get baseUrl => 'http://$host:$port';

  /// Start the GOWA process and wait for health check.
  Future<void> start() async {
    if (_stopped) throw StateError('GowaManager has been stopped');

    final gen = ++_generation;
    _log.info('Starting GOWA (gen $gen): $executable on $host:$port');

    final args = ['--host', host, '--port', port.toString()];
    if (dataDir != null) args.addAll(['--data', dataDir!]);

    try {
      _process = await _processFactory(executable, args);
    } catch (e) {
      _log.severe('Failed to spawn GOWA process', e);
      rethrow;
    }

    // Pipe stdout/stderr to logger
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.fine('[GOWA] $line'));
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.warning('[GOWA stderr] $line'));

    // Monitor for unexpected exit
    unawaited(_process!.exitCode.then((code) => _onExit(code, gen)));

    // Wait for health check
    if (!await _waitForHealth()) {
      throw StateError('GOWA failed health check after start');
    }

    _restartCount = 0;
    _log.info('GOWA started successfully (gen $gen)');
  }

  /// Stop the GOWA process gracefully.
  Future<void> stop() async {
    _stopped = true;
    final proc = _process;
    if (proc == null) return;
    _process = null;

    _log.info('Stopping GOWA');
    proc.kill(ProcessSignal.sigterm);

    // Wait up to 5s for graceful shutdown
    final exitCode = await proc.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _log.warning('GOWA did not exit within 5s, sending SIGKILL');
        proc.kill(ProcessSignal.sigkill);
        return proc.exitCode;
      },
    );
    _log.info('GOWA stopped (exit code: $exitCode)');
  }

  /// Dispose resources. Alias for [stop].
  Future<void> dispose() => stop();

  // ---- REST client methods ----

  /// Send a text message via GOWA.
  Future<void> sendText(String jid, String text) async {
    await _post('/api/send/text', {'jid': jid, 'text': text});
  }

  /// Send a media file via GOWA.
  Future<void> sendMedia(String jid, String filePath, {String? caption}) async {
    await _post('/api/send/media', {'jid': jid, 'file': filePath, 'caption': ?caption});
  }

  /// Get QR code data for WhatsApp pairing.
  Future<Map<String, dynamic>> getLoginStatus() async {
    return _get('/app/login');
  }

  /// Request a pairing code for a phone number.
  Future<Map<String, dynamic>> requestPairingCode(String phone) async {
    return _post('/app/pair', {'phone': phone});
  }

  // ---- Health check ----

  Future<bool> _waitForHealth({int maxAttempts = 10, Duration interval = const Duration(seconds: 1)}) async {
    for (var i = 0; i < maxAttempts; i++) {
      if (_stopped) return false;
      try {
        await _get('/');
        return true;
      } catch (_) {
        await _delay(interval);
      }
    }
    return false;
  }

  Future<bool> healthCheck() async {
    try {
      await _get('/');
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- Crash recovery ----

  void _onExit(int exitCode, int generation) {
    if (_stopped || generation != _generation) return;
    _process = null;

    _log.warning('GOWA exited unexpectedly (code: $exitCode, gen: $generation)');

    if (_restartCount >= maxRestartAttempts) {
      _log.severe('GOWA max restart attempts ($maxRestartAttempts) reached — giving up');
      return;
    }

    _restartCount++;
    final backoff = Duration(seconds: min(30, pow(2, _restartCount).toInt()));
    _log.info('Restarting GOWA in ${backoff.inSeconds}s (attempt $_restartCount/$maxRestartAttempts)');

    unawaited(
      Future(() async {
        await _delay(backoff);
        if (!_stopped) {
          try {
            await start();
          } catch (e) {
            _log.severe('GOWA restart failed', e);
          }
        }
      }),
    );
  }

  // ---- HTTP helpers ----

  Future<Map<String, dynamic>> _get(String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl$path'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('GOWA $path returned ${response.statusCode}: $body');
      }
      if (body.isEmpty) return {};
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> payload) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl$path'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('GOWA $path returned ${response.statusCode}: $body');
      }
      if (body.isEmpty) return {};
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }
}
