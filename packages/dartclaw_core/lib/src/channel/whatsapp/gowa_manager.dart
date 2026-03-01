import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../harness/claude_code_harness.dart' show ProcessFactory, DelayFactory;

/// Status record returned by [GowaManager.getStatus].
typedef GowaStatus = ({bool isConnected, bool isLoggedIn, String? deviceId});

/// Manages the GOWA (Go WhatsApp) sidecar binary as a subprocess.
///
/// Follows the ClaudeCodeHarness lifecycle pattern: spawn, health check,
/// crash recovery with exponential backoff.
///
/// Targets GOWA v8.3.2 API contract.
class GowaManager {
  static final _log = Logger('GowaManager');

  final String executable;
  final String host;
  final int port;
  final String? dbUri;
  final String? webhookUrl;
  final int maxRestartAttempts;
  final ProcessFactory _processFactory;
  final DelayFactory _delay;

  /// Timeout for standard API calls (sendText, getStatus, getLoginQr, requestPairingCode).
  static const _apiTimeout = Duration(seconds: 10);

  /// Timeout for media uploads (sendMedia / multipart).
  static const _mediaTimeout = Duration(seconds: 60);

  /// Timeout for GOWA to become reachable during startup.
  static const _startupTimeout = Duration(seconds: 30);

  Process? _process;
  int _generation = 0;
  int _restartCount = 0;
  bool _stopped = false;

  GowaManager({
    required this.executable,
    this.host = '127.0.0.1',
    this.port = 3000,
    this.dbUri,
    this.webhookUrl,
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

    final args = ['rest', '--host', host, '--port', port.toString()];
    if (dbUri != null) args.addAll(['--db-uri', dbUri!]);
    if (webhookUrl != null) args.add('--webhook=$webhookUrl');

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

    // Wait for GOWA server to become reachable (HTTP 200 on /app/status)
    if (!await _waitForHealth()) {
      // Kill the orphaned process before throwing
      _process?.kill(ProcessSignal.sigterm);
      _process = null;
      throw StateError('GOWA failed to respond within ${_startupTimeout.inSeconds}s');
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
    await _post('/send/message', {'phone': jid, 'message': text});
  }

  /// Send a media file via GOWA.
  ///
  /// Routes to type-specific endpoint based on file extension:
  /// - Images (.jpg, .jpeg, .png, .gif, .webp) → POST /send/image
  /// - Videos (.mp4, .mov, .avi, .webm) → POST /send/video
  /// - Everything else → POST /send/file
  Future<void> sendMedia(String jid, String filePath, {String? caption}) async {
    final ext = filePath.split('.').last.toLowerCase();
    final (path, field) = switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => ('/send/image', 'image'),
      'mp4' || 'mov' || 'avi' || 'webm' => ('/send/video', 'video'),
      _ => ('/send/file', 'file'),
    };
    await _postMultipart(path, filePath, field, {
      'phone': jid,
      if (caption != null) 'caption': caption,
    });
  }

  /// Get QR code link for WhatsApp pairing.
  ///
  /// Returns the QR image URL from `results.qr_link`, or null if not available.
  Future<String?> getLoginQr() async {
    final results = await _get('/app/login');
    return results['qr_link'] as String?;
  }

  /// Get GOWA connection/login status.
  Future<GowaStatus> getStatus() async {
    final results = await _get('/app/status');
    return (
      isConnected: results['is_connected'] as bool? ?? false,
      isLoggedIn: results['is_logged_in'] as bool? ?? false,
      deviceId: results['device_id'] as String?,
    );
  }

  /// Request a pairing code for a phone number.
  Future<Map<String, dynamic>> requestPairingCode(String phone) async {
    final encodedPhone = Uri.encodeQueryComponent(phone);
    return _get('/app/login-with-code?phone=$encodedPhone');
  }

  // ---- Health check ----

  Future<bool> _waitForHealth() async {
    final maxAttempts = _startupTimeout.inSeconds;
    for (var i = 0; i < maxAttempts; i++) {
      if (_stopped) return false;
      try {
        await _getRaw('/app/status');
        return true;
      } catch (_) {
        await _delay(const Duration(seconds: 1));
      }
    }
    return false;
  }

  /// Check if GOWA is connected to WhatsApp (not just reachable).
  Future<bool> healthCheck() async {
    try {
      final status = await getStatus();
      return status.isConnected;
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

  /// GET request that unwraps GOWA v8 response envelope, returning `results`.
  Future<Map<String, dynamic>> _get(String path) async {
    final raw = await _getRaw(path);
    return _unwrapEnvelope(raw);
  }

  /// Raw GET request (no envelope unwrapping). Used by health check.
  Future<Map<String, dynamic>> _getRaw(String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl$path'));
      final response = await request.close().timeout(_apiTimeout);
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

  /// POST request that unwraps GOWA v8 response envelope, returning `results`.
  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> payload) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl$path'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(_apiTimeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('GOWA $path returned ${response.statusCode}: $body');
      }
      if (body.isEmpty) return {};
      return _unwrapEnvelope(jsonDecode(body) as Map<String, dynamic>);
    } finally {
      client.close();
    }
  }

  /// POST multipart/form-data for media uploads.
  Future<void> _postMultipart(
    String path,
    String filePath,
    String fileField,
    Map<String, String> fields,
  ) async {
    final client = HttpClient();
    try {
      final boundary = 'dartclaw-${DateTime.now().millisecondsSinceEpoch}';
      final request = await client.postUrl(Uri.parse('$baseUrl$path'));
      request.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});

      final file = File(filePath);
      final fileName = file.uri.pathSegments.last;
      final fileBytes = await file.readAsBytes();

      final buffer = BytesBuilder();
      // Text fields
      for (final entry in fields.entries) {
        buffer.add(utf8.encode('--$boundary\r\n'));
        buffer.add(utf8.encode('Content-Disposition: form-data; name="${entry.key}"\r\n\r\n'));
        buffer.add(utf8.encode('${entry.value}\r\n'));
      }
      // File field
      buffer.add(utf8.encode('--$boundary\r\n'));
      buffer.add(utf8.encode('Content-Disposition: form-data; name="$fileField"; filename="$fileName"\r\n'));
      buffer.add(utf8.encode('Content-Type: application/octet-stream\r\n\r\n'));
      buffer.add(fileBytes);
      buffer.add(utf8.encode('\r\n'));
      buffer.add(utf8.encode('--$boundary--\r\n'));

      final bodyBytes = buffer.toBytes();
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close().timeout(_mediaTimeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('GOWA $path returned ${response.statusCode}: $body');
      }
    } finally {
      client.close();
    }
  }

  /// Unwrap GOWA v8 response envelope `{status, code, message, results}`.
  Map<String, dynamic> _unwrapEnvelope(Map<String, dynamic> raw) {
    final results = raw['results'];
    if (results is Map<String, dynamic>) return results;
    return raw;
  }
}
