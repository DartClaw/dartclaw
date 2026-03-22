import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart' show DelayFactory, HealthProbe, ProcessFactory;
import 'package:logging/logging.dart';

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
  final void Function(String phone)? onRegistered;
  final ProcessFactory _processFactory;
  final DelayFactory _delay;
  final HealthProbe? _healthProbe;

  /// Timeout for standard API calls.
  static const _apiTimeout = Duration(seconds: 10);

  /// Timeout for finishLink — must stay open until user scans QR on phone.
  static const _linkTimeout = Duration(minutes: 5);

  /// Timeout for signal-cli to become reachable during startup.
  static const _startupTimeout = Duration(seconds: 30);

  Process? _process;
  int _generation = 0;
  int _restartCount = 0;
  bool _stopped = false;
  bool _wasPaired = false;
  String? _pendingLinkUri;
  String? _registeredPhone;

  StreamController<Map<String, dynamic>> _eventController = StreamController<Map<String, dynamic>>.broadcast();
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
    this.onRegistered,
    ProcessFactory? processFactory,
    DelayFactory? delay,
    HealthProbe? healthProbe,
  }) : _processFactory = processFactory ?? Process.start,
       _delay = delay ?? Future.delayed,
       _healthProbe = healthProbe;

  bool get isRunning => _process != null && !_stopped;

  bool get wasPaired => _wasPaired;

  int get restartCount => _restartCount;

  /// The phone number confirmed by signal-cli after linking or account list.
  /// Null until first successful registration check.
  String? get registeredPhone => _registeredPhone;

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

    // Restore registered account state (phone number may differ from config placeholder).
    unawaited(isAccountRegistered());

    // Connect SSE stream — relays inbound message events from signal-cli daemon.
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

  /// Stop the process and reset state so [start] can be called again.
  ///
  /// Unlike [stop] (which is a permanent teardown), this prepares the manager
  /// for a fresh pairing cycle without recreating the object.
  Future<void> reset() async {
    final proc = _process;
    _process = null;

    await _sseSub?.cancel();
    _sseSub = null;
    _sseClient?.close(force: true);
    _sseClient = null;

    if (!_eventController.isClosed) await _eventController.close();
    _eventController = StreamController<Map<String, dynamic>>.broadcast();

    _stopped = false;
    _wasPaired = false;
    _pendingLinkUri = null;
    _registeredPhone = null;
    _restartCount = 0;
    _reconnecting = false;

    if (proc != null) {
      _log.info('Resetting signal-cli');
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

  // ---- JSON-RPC client methods ----

  /// Send a text message via signal-cli JSON-RPC.
  Future<void> sendMessage(String recipient, String text) async {
    await _rpc('send', {
      'account': phoneNumber,
      'recipient': [recipient],
      'message': text,
    });
  }

  /// Returns true if any Signal account is registered in signal-cli.
  ///
  /// Short-circuits to true if [_wasPaired] is already set (e.g. finishLink
  /// just completed), since signal-cli may not reflect the new account in
  /// listAccounts until after finishLink's HTTP response is fully processed.
  ///
  /// Also caches the registered phone number in [_registeredPhone] — this
  /// handles the case where [phoneNumber] is a config placeholder.
  Future<bool> isAccountRegistered() async {
    if (_wasPaired) return true;
    try {
      final result = await _rpc('listAccounts', {});
      if (result is List && result.isNotEmpty) {
        for (final e in result) {
          final num = e is String ? e : (e is Map ? (e['number'] ?? e['account'])?.toString() : null);
          if (num != null && num.isNotEmpty) {
            _registeredPhone ??= num;
            break;
          }
        }
        if (_registeredPhone != null) {
          _wasPaired = true;
          _notifyRegistered(_registeredPhone!);
          return true;
        }
      }
      return false;
    } catch (e) {
      _log.fine('isAccountRegistered check failed: $e');
      return false;
    }
  }

  /// Fires [onRegistered] the first time a phone number is confirmed.
  ///
  /// Only fires when the discovered number differs from [phoneNumber] (the
  /// config value), so it's a no-op when the config is already correct.
  void _notifyRegistered(String phone) {
    if (phone != phoneNumber) onRegistered?.call(phone);
  }

  /// Returns the `sgnl://...` URI for device-linking registration.
  ///
  /// Calls `startLink` once and caches the URI. Subsequent calls return the
  /// cached URI while the link is in progress, avoiding duplicate startLink /
  /// finishLink calls on each polling request.
  ///
  /// `finishLink` is long-polled with a 5-minute timeout — signal-cli holds
  /// the connection open until the user confirms on the phone.
  Future<String?> getLinkDeviceUri({String deviceName = 'DartClaw'}) async {
    // Return cached URI while a link session is already in progress.
    if (_pendingLinkUri != null) return _pendingLinkUri;

    try {
      final result = await _rpc('startLink', {});
      final uri = result is Map
          ? (result['deviceLinkUri'] as String? ?? result['uri'] as String?)
          : (result is String ? result : null);
      if (uri == null) return null;

      _pendingLinkUri = uri;

      // finishLink is a long-poll: stays open until phone confirms or times out.
      unawaited(
        _rpc('finishLink', {'deviceLinkUri': uri, 'deviceName': deviceName}, timeout: _linkTimeout)
            .then((result) {
              _pendingLinkUri = null;
              _wasPaired = true; // Account is now registered — unblock isAccountRegistered()
              if (result is Map) {
                _registeredPhone = result['number'] as String? ?? result['account'] as String?;
              }
              _log.info('finishLink completed: $result');
              if (_registeredPhone != null) _notifyRegistered(_registeredPhone!);
              // Reconnect SSE so signal-cli routes events for the newly linked account.
              unawaited(_reconnectSse());
            })
            .catchError((Object e) {
              // Connection close is expected when user disconnects or
              // signal-cli restarts — log at fine, not warning.
              final msg = e.toString();
              if (msg.contains('Connection closed') || msg.contains('IOException')) {
                _log.fine('finishLink cancelled (connection closed)');
              } else {
                _log.warning('finishLink failed', e);
              }
              _pendingLinkUri = null;
            }),
      );

      return uri;
    } catch (e) {
      _log.warning('startLink failed', e);
      return null;
    }
  }

  /// Sends an SMS verification code to [phone] (defaults to [phoneNumber]).
  ///
  /// If Signal requires a captcha, pass [captcha] with the token from
  /// https://signalcaptchas.org/registration/generate.html
  Future<void> requestSmsVerification({String? phone, String? captcha}) async {
    final params = <String, dynamic>{'account': phone ?? phoneNumber};
    if (captcha != null) params['captcha'] = captcha;
    await _rpc('register', params);
  }

  /// Requests a voice call verification to [phone] (defaults to [phoneNumber]).
  Future<void> requestVoiceVerification({String? phone, String? captcha}) async {
    final params = <String, dynamic>{'account': phone ?? phoneNumber, 'voice': true};
    if (captcha != null) params['captcha'] = captcha;
    await _rpc('register', params);
  }

  /// Verifies [code] received via SMS and completes registration.
  Future<void> verifySmsCode(String code, {String? phone}) async {
    await _rpc('verify', {'account': phone ?? phoneNumber, 'verificationCode': code});
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
    } catch (e) {
      _log.fine('Signal health check failed: $e');
      return false;
    }
  }

  Future<bool> _waitForHealth() async {
    final probe = _healthProbe ?? healthCheck;
    final maxAttempts = _startupTimeout.inSeconds;
    for (var i = 0; i < maxAttempts; i++) {
      if (_stopped) return false;
      if (await probe()) return true;
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
                    _log.fine('SSE envelope received, dispatching to channel');
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
  ///
  /// [timeout] overrides [_apiTimeout] for long-poll calls like `finishLink`.
  Future<dynamic> _rpc(String method, Map<String, dynamic> params, {Duration? timeout}) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/api/v1/rpc'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'jsonrpc': '2.0', 'id': (++_rpcId).toString(), 'method': method, 'params': params}));
      final response = await request.close().timeout(timeout ?? _apiTimeout);
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
