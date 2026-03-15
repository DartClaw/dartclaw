import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Status record returned by [GowaManager.getStatus].
typedef GowaStatus = ({bool isConnected, bool isLoggedIn, String? deviceId});

/// QR login data returned by [GowaManager.getLoginQr].
typedef GowaLoginQr = ({String? url, int durationSeconds});

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
  final String osName;
  final int maxRestartAttempts;
  final ProcessFactory _processFactory;
  final DelayFactory _delay;
  final HealthProbe? _healthProbe;

  /// Timeout for standard API calls (sendText, getStatus, getLoginQr, requestPairingCode).
  static const _apiTimeout = Duration(seconds: 10);

  /// Timeout for media uploads (sendMedia / multipart).
  static const _mediaTimeout = Duration(seconds: 60);

  /// Timeout for GOWA to become reachable during startup.
  static const _startupTimeout = Duration(seconds: 30);

  /// Regex to extract the WhatsApp JID from GOWA's LOGIN_SUCCESS stderr line.
  ///
  /// Example: `msg="message received: {LOGIN_SUCCESS Successfully pair with 46725619417:4@s.whatsapp.net <nil>}"`
  static final _loginSuccessRe = RegExp(r'LOGIN_SUCCESS\b.*?\b(\d[\d]+:\d+@s\.whatsapp\.net)\b');

  Process? _process;
  int _generation = 0;
  int _restartCount = 0;
  bool _stopped = false;
  bool _wasPaired = false;
  bool _usingExternalService = false;
  String? _deviceId;
  String? _pairedJid;

  GowaManager({
    required this.executable,
    this.host = '127.0.0.1',
    this.port = 3000,
    this.dbUri,
    this.webhookUrl,
    this.osName = 'DartClaw',
    this.maxRestartAttempts = 5,
    ProcessFactory? processFactory,
    DelayFactory? delay,
    HealthProbe? healthProbe,
  }) : _processFactory = processFactory ?? Process.start,
       _delay = delay ?? Future.delayed,
       _healthProbe = healthProbe;

  bool get isRunning => (_process != null || _usingExternalService) && !_stopped;

  bool get wasPaired => _wasPaired;

  /// The WhatsApp JID captured from the LOGIN_SUCCESS event, if available.
  ///
  /// Format: `PHONENUMBER:DEVICE@s.whatsapp.net` (e.g. `46725619417:4@s.whatsapp.net`).
  /// This is the actual paired identity — distinct from [_deviceId] which is
  /// GOWA's internal device UUID.
  String? get pairedJid => _pairedJid;

  int get restartCount => _restartCount;

  String get baseUrl => 'http://$host:$port';

  /// Start the GOWA process and wait for health check.
  Future<void> start() async {
    if (_stopped) throw StateError('GowaManager has been stopped');

    final gen = ++_generation;
    _log.info('Starting GOWA (gen $gen): $executable on $host:$port');

    if (await _isServiceReachable()) {
      _usingExternalService = true;
      await _ensureDevice();
      _restartCount = 0;
      _log.info('Using existing GOWA service on $host:$port');
      _log.info('GOWA started successfully (gen $gen)');
      return;
    }

    final args = ['rest', '--host', host, '--port', port.toString(), '--os', osName];
    if (dbUri != null) args.addAll(['--db-uri', dbUri!]);
    if (webhookUrl != null) args.add('--webhook=$webhookUrl');

    try {
      _process = await _processFactory(executable, args);
      _usingExternalService = false;
    } catch (e) {
      _log.severe('Failed to spawn GOWA process', e);
      rethrow;
    }

    // Pipe stdout/stderr to logger
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.fine('[GOWA] $line'));
    _process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _log.warning('[GOWA stderr] $line');
      // Capture the WhatsApp JID from LOGIN_SUCCESS events.
      final m = _loginSuccessRe.firstMatch(line);
      if (m != null) {
        _pairedJid = m.group(1);
        _wasPaired = true;
        _log.info('Captured paired JID: $_pairedJid');
      }
    });

    // Monitor for unexpected exit
    unawaited(_process!.exitCode.then((code) => _onExit(code, gen)));

    // Wait for GOWA server to become reachable
    if (!await _waitForHealth()) {
      _process?.kill(ProcessSignal.sigterm);
      _process = null;
      throw StateError('GOWA failed to respond within ${_startupTimeout.inSeconds}s');
    }

    // Ensure a device exists (GOWA v8 multi-device requires X-Device-Id).
    await _ensureDevice();

    _restartCount = 0;
    _log.info('GOWA started successfully (gen $gen)');
  }

  /// Stop the GOWA process gracefully.
  Future<void> stop() async {
    _stopped = true;
    final proc = _process;
    if (proc == null) return;
    _process = null;
    _usingExternalService = false;

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

  /// Stop the process and reset state so [start] can be called again.
  ///
  /// Unlike [stop] (which is a permanent teardown), this prepares the manager
  /// for a fresh pairing cycle without recreating the object.
  Future<void> reset() async {
    final proc = _process;
    _process = null;

    _stopped = false;
    _wasPaired = false;
    _usingExternalService = false;
    _deviceId = null;
    _pairedJid = null;
    _restartCount = 0;

    if (proc != null) {
      _log.info('Resetting GOWA');
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return proc.exitCode;
        },
      );
    }
  }

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
    await _postMultipart(path, filePath, field, {'phone': jid, 'caption': ?caption});
  }

  /// Get QR code link for WhatsApp pairing.
  ///
  /// Returns [GowaLoginQr] with the QR image URL and expiry duration in seconds.
  /// URL is null when no QR is available. Duration defaults to 60s if not
  /// provided by GOWA.
  Future<GowaLoginQr> getLoginQr() async {
    final results = await _get('/app/login');
    return (url: results['qr_link'] as String?, durationSeconds: (results['qr_duration'] as num?)?.toInt() ?? 60);
  }

  /// Get GOWA connection/login status.
  ///
  /// When no device is registered (pre-pairing), GOWA returns 400 with
  /// `DEVICE_ID_REQUIRED` — treated as not-logged-in rather than an error.
  /// When the stored device ID is stale (e.g. GOWA restarted with in-memory
  /// storage), GOWA returns 404 with `DEVICE_NOT_FOUND` — re-provision and
  /// return not-connected so the pairing flow can proceed.
  Future<GowaStatus> getStatus() async {
    try {
      final results = await _get('/app/status');
      final loggedIn = results['is_logged_in'] as bool? ?? false;
      if (loggedIn) {
        _wasPaired = true;
        // Lazily resolve the paired JID from /devices when first needed.
        if (_pairedJid == null) await _resolveJidFromDevices();
      }
      return (
        isConnected: results['is_connected'] as bool? ?? false,
        isLoggedIn: loggedIn,
        deviceId: results['device_id'] as String?,
      );
    } on HttpException catch (e) {
      if (e.message.contains('DEVICE_ID_REQUIRED')) {
        return (isConnected: false, isLoggedIn: false, deviceId: null);
      }
      if (e.message.contains('DEVICE_NOT_FOUND')) {
        // Stale device ID — clear and re-provision so subsequent calls work.
        _deviceId = null;
        await _ensureDevice();
        return (isConnected: false, isLoggedIn: false, deviceId: null);
      }
      rethrow;
    }
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
      if (_healthProbe != null) {
        if (await _healthProbe()) return true;
      } else {
        try {
          await _getRaw('/app/status');
          return true;
        } on HttpException {
          // Any HTTP error (e.g. DEVICE_ID_REQUIRED, DEVICE_NOT_FOUND) means GOWA is up.
          return true;
        } catch (_) {
          // Connection failed — retry after delay
        }
      }
      await _delay(const Duration(seconds: 1));
    }
    return false;
  }

  Future<bool> _isServiceReachable() async {
    if (_healthProbe != null) {
      return _healthProbe();
    }

    try {
      await _getRaw('/app/status');
      return true;
    } on HttpException {
      // The sidecar is reachable even if the specific request requires a device.
      return true;
    } catch (_) {
      return false;
    }
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

  // ---- Device provisioning (GOWA v8 multi-device) ----

  /// Fetches the WhatsApp JID from the `/devices` list.
  ///
  /// Called lazily from [getStatus] when `_pairedJid` is still null after
  /// login is confirmed. This handles the race where GOWA wasn't fully
  /// logged in yet during [_ensureDevice] at startup.
  Future<void> _resolveJidFromDevices() async {
    try {
      final raw = await _getRaw('/devices');
      final results = raw['results'];
      if (results is List) {
        for (final entry in results) {
          if (entry is Map<String, dynamic>) {
            final jid = entry['jid']?.toString();
            if (jid != null && jid.contains('@')) {
              _pairedJid = jid;
              _log.info('Resolved paired JID from /devices: $_pairedJid');
              return;
            }
          }
        }
      }
    } catch (e) {
      _log.fine('Could not resolve JID from /devices: $e');
    }
  }

  /// Ensures a GOWA device exists, reusing the first existing device or
  /// creating one. Sets [_deviceId] for all subsequent API calls.
  Future<void> _ensureDevice() async {
    // Try listing existing devices first.
    try {
      final raw = await _getRaw('/devices');
      final results = raw['results'];
      if (results is List && results.isNotEmpty) {
        final first = results[0] as Map<String, dynamic>;
        _deviceId = (first['id'] ?? first['device_id'])?.toString();
        if (_deviceId != null) {
          // Check if any device indicates a previously paired session
          // and capture the WhatsApp JID from the device record.
          for (final entry in results) {
            if (entry is Map<String, dynamic>) {
              final state = entry['state']?.toString();
              if (state == 'connected' || state == 'logged_in') {
                _wasPaired = true;
                _pairedJid ??= entry['jid']?.toString();
                break;
              }
            }
          }
          _log.fine('Using existing GOWA device: $_deviceId (jid: $_pairedJid)');
          return;
        }
      }
    } catch (e) {
      _log.fine('Could not list devices: $e');
    }

    // No device found — create one.
    try {
      final raw = await _postRaw('/devices', {});
      final results = raw['results'] as Map<String, dynamic>?;
      _deviceId = (results?['id'] ?? results?['device_id'])?.toString();
      _log.info('Created GOWA device: $_deviceId');
    } catch (e) {
      _log.warning('Failed to create GOWA device: $e');
    }
  }

  // ---- HTTP helpers ----

  void _addDeviceHeader(HttpClientRequest request) {
    if (_deviceId != null) {
      request.headers.set('X-Device-Id', _deviceId!);
    }
  }

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
      _addDeviceHeader(request);
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

  /// Raw POST request (no envelope unwrapping). Used by device provisioning.
  Future<Map<String, dynamic>> _postRaw(String path, Map<String, dynamic> payload) async {
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
      _addDeviceHeader(request);
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
  Future<void> _postMultipart(String path, String filePath, String fileField, Map<String, String> fields) async {
    final client = HttpClient();
    try {
      final boundary = 'dartclaw-${DateTime.now().millisecondsSinceEpoch}';
      final request = await client.postUrl(Uri.parse('$baseUrl$path'));
      _addDeviceHeader(request);
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
