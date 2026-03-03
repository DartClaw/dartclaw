import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';

import '../../harness/claude_code_harness.dart' show ProcessFactory, DelayFactory;

/// Manages signal-cli as a subprocess in daemon HTTP mode.
///
/// Mirrors [GowaManager] for WhatsApp: spawn, health check, crash recovery
/// with exponential backoff. Communicates via signal-cli's native JSON-RPC
/// and SSE endpoints.
class SignalCliManager {
  static final _log = Logger('SignalCliManager');

  final String executable;
  final String host;
  final int port;
  final String phoneNumber;
  final int maxRestartAttempts;
  final ProcessFactory _processFactory;
  final DelayFactory _delay;

  /// Timeout for standard API calls.
  static const _apiTimeout = Duration(seconds: 10);

  /// Timeout for signal-cli to become reachable during startup.
  static const _startupTimeout = Duration(seconds: 30);

  Process? _process;
  int _generation = 0;
  int _restartCount = 0;
  bool _stopped = false;

  final StreamController<Map<String, dynamic>> _eventController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<String>? _sseSub;
  HttpClient? _sseClient;
  bool _reconnecting = false;
  int _rpcId = 0;

  SignalCliManager({
    required this.executable,
    this.host = '127.0.0.1',
    this.port = 8080,
    required this.phoneNumber,
    this.maxRestartAttempts = 5,
    ProcessFactory? processFactory,
    DelayFactory? delay,
  }) : _processFactory = processFactory ?? Process.start,
       _delay = delay ?? Future.delayed;

  bool get isRunning => _process != null && !_stopped;

  String get baseUrl => 'http://$host:$port';

  /// SSE event stream — emits parsed envelope maps from inbound messages.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  /// Start the signal-cli daemon process and wait for health check.
  Future<void> start() async {
    if (_stopped) throw StateError('SignalCliManager has been stopped');

    final gen = ++_generation;
    _log.info('Starting signal-cli (gen $gen): $executable on $host:$port');

    final args = ['daemon', '--http', '$host:$port'];

    try {
      _process = await _processFactory(executable, args);
    } catch (e) {
      _log.severe('Failed to spawn signal-cli process', e);
      rethrow;
    }

    // Pipe stdout/stderr to logger
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.fine('[signal-cli] $line'));
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.warning('[signal-cli stderr] $line'));

    // Monitor for unexpected exit
    unawaited(_process!.exitCode.then((code) => _onExit(code, gen)));

    // Wait for daemon to become reachable
    if (!await _waitForHealth()) {
      _process?.kill(ProcessSignal.sigterm);
      _process = null;
      throw StateError('signal-cli failed to respond within ${_startupTimeout.inSeconds}s');
    }

    _restartCount = 0;
    _log.info('signal-cli started successfully (gen $gen)');

    // Connect SSE event stream
    unawaited(_connectSse());
  }

  /// Stop the signal-cli process gracefully.
  Future<void> stop() async {
    _stopped = true;
    await _sseSub?.cancel();
    _sseSub = null;
    _sseClient?.close(force: true);
    _sseClient = null;
    await _eventController.close();

    final proc = _process;
    if (proc == null) return;
    _process = null;

    _log.info('Stopping signal-cli');
    proc.kill(ProcessSignal.sigterm);

    // Wait up to 5s for graceful shutdown
    final exitCode = await proc.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _log.warning('signal-cli did not exit within 5s, sending SIGKILL');
        proc.kill(ProcessSignal.sigkill);
        return proc.exitCode;
      },
    );
    _log.info('signal-cli stopped (exit code: $exitCode)');
  }

  /// Dispose resources. Alias for [stop].
  Future<void> dispose() => stop();

  // ---- JSON-RPC client methods ----

  /// Send a text message via signal-cli JSON-RPC.
  Future<void> sendMessage(String recipient, String text) async {
    await _rpc('send', {
      'account': phoneNumber,
      'recipient': [recipient],
      'message': text,
    });
  }

  /// Returns true if [phoneNumber] is registered/linked in signal-cli.
  Future<bool> isAccountRegistered() async {
    try {
      final result = await _rpc('listAccounts', {});
      if (result is List) {
        return result.any(
          (e) => e == phoneNumber || (e is Map && (e['number'] == phoneNumber || e['account'] == phoneNumber)),
        );
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Returns the `sgnl://...` URI for device-linking registration.
  ///
  /// Calls `startLink` to get the URI, then fires off `finishLink` in the
  /// background (blocks until user confirms on phone).
  Future<String?> getLinkDeviceUri({String deviceName = 'DartClaw'}) async {
    try {
      final result = await _rpc('startLink', {});
      final uri = result is Map
          ? (result['deviceLinkUri'] as String? ?? result['uri'] as String?)
          : (result is String ? result : null);
      if (uri == null) return null;

      // Fire-and-forget: finishLink blocks until user confirms on phone
      unawaited(
        _rpc('finishLink', {'deviceLinkUri': uri, 'deviceName': deviceName}).catchError((e) {
          _log.warning('finishLink failed', e);
        }),
      );

      return uri;
    } catch (e) {
      _log.warning('startLink failed', e);
      return null;
    }
  }

  /// Sends an SMS verification code to [phoneNumber].
  Future<void> requestSmsVerification() async {
    await _rpc('register', {'account': phoneNumber});
  }

  /// Verifies [code] received via SMS and completes registration.
  Future<void> verifySmsCode(String code) async {
    await _rpc('verify', {'account': phoneNumber, 'verificationCode': code});
  }

  // ---- Health check ----

  /// Single health probe against the daemon.
  Future<bool> healthCheck() async {
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('$baseUrl/api/v1/check'));
        final response = await request.close().timeout(_apiTimeout);
        await response.drain<void>();
        return response.statusCode < 400;
      } finally {
        client.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _waitForHealth() async {
    final maxAttempts = _startupTimeout.inSeconds;
    for (var i = 0; i < maxAttempts; i++) {
      if (_stopped) return false;
      if (await healthCheck()) return true;
      await _delay(const Duration(seconds: 1));
    }
    return false;
  }

  // ---- SSE event stream ----

  Future<void> _connectSse() async {
    if (_stopped) return;

    try {
      _sseClient?.close(force: true);
      final client = HttpClient();
      _sseClient = client;
      final request = await client.getUrl(Uri.parse('$baseUrl/api/v1/events'));
      final response = await request.close();

      _sseSub = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!line.startsWith('data:')) return;
              final json = line.substring(5).trim();
              if (json.isEmpty) return;
              try {
                final parsed = jsonDecode(json);
                if (parsed is Map<String, dynamic>) {
                  // Extract envelope from JSON-RPC notification params
                  final params = parsed['params'] as Map<String, dynamic>?;
                  final envelope = params?['envelope'] as Map<String, dynamic>?;
                  if (envelope != null) {
                    _eventController.add({'envelope': envelope});
                  } else {
                    // Pass through as-is if no envelope wrapper
                    _eventController.add(parsed);
                  }
                }
              } catch (e) {
                _log.fine('Failed to parse SSE event: $e');
              }
            },
            onError: (Object e) {
              _log.warning('SSE stream error', e);
              if (!_stopped) unawaited(_reconnectSse());
            },
            onDone: () {
              if (!_stopped) {
                _log.info('SSE stream closed, reconnecting');
                unawaited(_reconnectSse());
              }
            },
          );
    } catch (e) {
      _log.warning('Failed to connect SSE', e);
      if (!_stopped) unawaited(_reconnectSse());
    }
  }

  Future<void> _reconnectSse() async {
    if (_reconnecting) return; // Single-flight guard (P1)
    _reconnecting = true;
    try {
      await _sseSub?.cancel();
      _sseSub = null;
      _sseClient?.close(force: true);
      _sseClient = null;
      await _delay(const Duration(seconds: 2));
      if (!_stopped) await _connectSse();
    } finally {
      _reconnecting = false;
    }
  }

  // ---- Crash recovery ----

  void _onExit(int exitCode, int generation) {
    if (_stopped || generation != _generation) return;
    _process = null;

    _log.warning('signal-cli exited unexpectedly (code: $exitCode, gen: $generation)');

    if (_restartCount >= maxRestartAttempts) {
      _log.severe('signal-cli max restart attempts ($maxRestartAttempts) reached — giving up');
      return;
    }

    _restartCount++;
    final backoff = Duration(seconds: min(30, pow(2, _restartCount).toInt()));
    _log.info(
      'Restarting signal-cli in ${backoff.inSeconds}s '
      '(attempt $_restartCount/$maxRestartAttempts)',
    );

    unawaited(() async {
      await _delay(backoff);
      if (!_stopped) {
        try {
          await start();
        } catch (e) {
          _log.severe('signal-cli restart failed', e);
        }
      }
    }());
  }

  // ---- JSON-RPC helper ----

  /// Send a JSON-RPC 2.0 request to signal-cli daemon.
  Future<dynamic> _rpc(String method, Map<String, dynamic> params) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/api/v1/rpc'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'jsonrpc': '2.0', 'id': (++_rpcId).toString(), 'method': method, 'params': params}));
      final response = await request.close().timeout(_apiTimeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('signal-cli RPC $method returned ${response.statusCode}: $body');
      }
      if (body.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      if (decoded.containsKey('error')) {
        final error = decoded['error'];
        throw HttpException('signal-cli RPC $method error: ${error is Map ? error['message'] : error}');
      }
      return decoded['result'];
    } finally {
      client.close();
    }
  }
}
