import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart' show SidecarProcessManager;
import 'package:logging/logging.dart';

/// Status record returned by [GowaManager.status].
typedef GowaStatus = ({bool isConnected, bool isLoggedIn, String? deviceId});

/// QR login data returned by [GowaManager.loginQr].
typedef GowaLoginQr = ({String? url, int durationSeconds});

/// Manages the GOWA (Go WhatsApp) sidecar binary as a subprocess.
///
/// Spawn, health check and crash recovery come from [SidecarProcessManager];
/// this class owns the GOWA sequence around them, including attaching to an
/// already-running service instead of spawning one.
///
/// Targets GOWA v8.3.2 API contract.
class GowaManager extends SidecarProcessManager {
  new({
    required super.executable,
    super.host = '127.0.0.1',
    super.port = 3000,
    this.dbUri,
    this.webhookUrl,
    this.osName = 'DartClaw',
    super.maxRestartAttempts = 5,
    super.processFactory,
    super.delay,
    super.healthProbe,
    super.platformCapabilities,
    super.terminationGracePeriod,
  }) : super(label: 'GOWA', log: Logger('GowaManager'));

  final String? dbUri;
  final String? webhookUrl;
  final String osName;

  /// Timeout for standard API calls (sendText, chat presence, status, loginQr, requestPairingCode).
  static const _apiTimeout = Duration(seconds: 10);

  /// Timeout for media uploads (sendMedia / multipart).
  static const _mediaTimeout = Duration(seconds: 60);

  /// Regex to extract the WhatsApp JID from GOWA's LOGIN_SUCCESS stderr line.
  ///
  /// Example: `msg="message received: {LOGIN_SUCCESS Successfully pair with 46725619417:4@s.whatsapp.net <nil>}"`
  static final _loginSuccessRe = RegExp(r'LOGIN_SUCCESS\b.*?\b(\d[\d]+:\d+@s\.whatsapp\.net)\b');

  bool _usingExternalService = false;
  String? _deviceId;
  String? _pairedJid;

  @override
  bool get isRunning => (process != null || _usingExternalService) && !stopRequested;

  /// The WhatsApp JID captured from the LOGIN_SUCCESS event, if available.
  ///
  /// Format: `PHONENUMBER:DEVICE@s.whatsapp.net` (e.g. `46725619417:4@s.whatsapp.net`).
  /// This is the actual paired identity — distinct from [_deviceId] which is
  /// GOWA's internal device UUID.
  String? get pairedJid => _pairedJid;

  /// Start the GOWA process and wait for health check.
  @override
  Future<void> start() => withLock(_start);

  Future<void> _start() async {
    if (stopRequested) throw StateError('GowaManager has been stopped');
    if (process != null) throw StateError('GowaManager still owns a GOWA process; stop it before restarting');

    final gen = ++generation;
    log.info('Starting GOWA (gen $gen): $executable on $host:$port');

    if (await _isServiceReachable()) {
      _usingExternalService = true;
      await _ensureDevice();
      restartCount = 0;
      log.info('Using existing GOWA service on $host:$port');
      log.info('GOWA started successfully (gen $gen)');
      return;
    }

    final args = ['rest', '--host', host, '--port', port.toString(), '--os', osName];
    if (dbUri != null) args.addAll(['--db-uri', dbUri!]);
    if (webhookUrl != null) args.add('--webhook=$webhookUrl');

    final spawned = await spawnProcess(args);
    _usingExternalService = false;
    attachProcess(spawned, gen, onStderrLine: _captureLoginSuccess);

    if (!await waitForStartupHealth()) await abortFailedStartup();

    // Ensure a device exists (GOWA v8 multi-device requires X-Device-Id).
    await _ensureDevice();

    restartCount = 0;
    log.info('GOWA started successfully (gen $gen)');
  }

  void _captureLoginSuccess(String line) {
    final m = _loginSuccessRe.firstMatch(line);
    if (m != null) {
      _pairedJid = m.group(1);
      wasPaired = true;
      log.info('Captured paired JID: $_pairedJid');
    }
  }

  /// Stop the GOWA process gracefully.
  @override
  Future<void> stop() {
    stopRequested = true;
    beginIntentionalProcessTeardown(process);
    return withLock(_stop);
  }

  Future<void> _stop() async {
    final proc = process;
    if (proc == null) return;
    _usingExternalService = false;

    await stopOwnedProcess(proc);
  }

  /// Stop the process and reset state so [start] can be called again.
  ///
  /// Unlike [stop] (which is a permanent teardown), this prepares the manager
  /// for a fresh pairing cycle without recreating the object.
  @override
  Future<void> reset() {
    beginIntentionalProcessTeardown(process);
    return withLock(_reset);
  }

  Future<void> _reset() async {
    ++generation;
    final proc = process;
    beginIntentionalProcessTeardown(proc);

    if (proc != null) await resetOwnedProcess(proc);

    stopRequested = false;
    wasPaired = false;
    _usingExternalService = false;
    _deviceId = null;
    _pairedJid = null;
    restartCount = 0;
  }

  // ---- REST client methods ----

  /// Send a text message via GOWA.
  Future<void> sendText(String jid, String text) async {
    await _post('/send/message', {'phone': jid, 'message': text});
  }

  /// Starts or stops chat presence for a direct recipient or group.
  Future<void> sendChatPresence(String jid, {required bool isTyping}) async {
    await _post('/send/chat-presence', {
      'phone': jid,
      'action': isTyping ? 'start' : 'stop',
    }, timeout: const Duration(seconds: 1));
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
  Future<GowaLoginQr> loginQr() async {
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
  Future<GowaStatus> status() async {
    try {
      final results = await _get('/app/status');
      final loggedIn = results['is_logged_in'] as bool? ?? false;
      if (loggedIn) {
        wasPaired = true;
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

  @override
  Future<bool> defaultStartupProbe(int attempt) async {
    try {
      await _getRaw('/app/status');
      return true;
    } on HttpException {
      // Any HTTP error (e.g. DEVICE_ID_REQUIRED, DEVICE_NOT_FOUND) means GOWA is up.
      return true;
    } catch (e) {
      log.fine('GOWA health probe attempt $attempt failed: $e');
      return false;
    }
  }

  Future<bool> _isServiceReachable() async {
    final probe = healthProbe;
    if (probe != null) {
      return probe();
    }

    try {
      await _getRaw('/app/status');
      return true;
    } on HttpException {
      // The sidecar is reachable even if the specific request requires a device.
      return true;
    } catch (e) {
      log.fine('GOWA service not reachable: $e');
      return false;
    }
  }

  /// Check if GOWA is connected to WhatsApp (not just reachable).
  Future<bool> healthCheck() async {
    try {
      final currentStatus = await status();
      return currentStatus.isConnected;
    } catch (e) {
      log.fine('GOWA health check failed: $e');
      return false;
    }
  }

  // ---- Crash recovery ----

  /// Defers the retry to a later event-loop turn, so an exit observed inside a
  /// lifecycle call cannot re-enter [start] before that call unwinds.
  @override
  void scheduleRestart(Duration backoff, int generation) {
    unawaited(
      Future(() async {
        await runScheduledRestart(backoff, generation);
      }),
    );
  }

  // ---- Device provisioning (GOWA v8 multi-device) ----

  /// Fetches the WhatsApp JID from the `/devices` list.
  ///
  /// Called lazily from [status] when `_pairedJid` is still null after
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
              log.info('Resolved paired JID from /devices: $_pairedJid');
              return;
            }
          }
        }
      }
    } catch (e) {
      log.fine('Could not resolve JID from /devices: $e');
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
                wasPaired = true;
                _pairedJid ??= entry['jid']?.toString();
                break;
              }
            }
          }
          log.fine('Using existing GOWA device: $_deviceId (jid: $_pairedJid)');
          return;
        }
      }
    } catch (e) {
      log.fine('Could not list devices: $e');
    }

    // No device found — create one.
    try {
      final raw = await _postRaw('/devices', {});
      final results = raw['results'] as Map<String, dynamic>?;
      _deviceId = (results?['id'] ?? results?['device_id'])?.toString();
      log.info('Created GOWA device: $_deviceId');
    } catch (e) {
      log.warning('Failed to create GOWA device: $e');
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
      return await _decodeRawResponse(response, path);
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
      return await _decodeRawResponse(response, path);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _decodeRawResponse(HttpClientResponse response, String path) async {
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      throw HttpException('GOWA $path returned ${response.statusCode}: $body');
    }
    if (body.isEmpty) return {};
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// POST request that unwraps GOWA v8 response envelope, returning `results`.
  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload, {
    Duration timeout = _apiTimeout,
  }) async {
    final client = HttpClient();
    try {
      return await (() async {
        final request = await client.postUrl(Uri.parse('$baseUrl$path'));
        _addDeviceHeader(request);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(payload));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode >= 400) {
          throw HttpException('GOWA $path returned ${response.statusCode}: $body');
        }
        if (body.isEmpty) return <String, dynamic>{};
        return _unwrapEnvelope(jsonDecode(body) as Map<String, dynamic>);
      }()).timeout(
        timeout,
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('GOWA $path timed out', timeout);
        },
      );
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
