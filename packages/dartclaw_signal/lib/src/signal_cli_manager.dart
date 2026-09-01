import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SidecarProcessManager;
import 'package:logging/logging.dart';

/// Result of querying signal-cli for a registered account.
enum SignalRegistrationState { registered, unregistered, unknown }

/// Manages signal-cli as a subprocess in daemon HTTP mode.
///
/// Spawn, health check and crash recovery come from [SidecarProcessManager];
/// this class owns the signal-cli sequence around them, plus the native
/// JSON-RPC and SSE transports.
class SignalCliManager extends SidecarProcessManager {
  new({
    required super.executable,
    super.host = '127.0.0.1',
    super.port = 8080,
    required this.phoneNumber,
    super.maxRestartAttempts = 5,
    this.onRegistered,
    super.processFactory,
    super.delay,
    super.healthProbe,
    super.platformCapabilities,
    super.terminationGracePeriod,
    Duration sseHandshakeTimeout = _apiTimeout,
  }) : _sseHandshakeTimeout = sseHandshakeTimeout,
       super(label: 'signal-cli', log: Logger('SignalCliManager'));

  final String phoneNumber;
  final void Function(String phone)? onRegistered;
  final Duration _sseHandshakeTimeout;

  /// Timeout for standard API calls.
  static const _apiTimeout = Duration(seconds: 10);

  /// Timeout for finishLink — must stay open until user scans QR on phone.
  static const _linkTimeout = Duration(minutes: 5);

  String? _pendingLinkUri;
  int? _pendingLinkGeneration;
  Future<String?>? _linkFuture;
  int? _linkGeneration;
  String? _registeredPhone;

  StreamController<Map<String, dynamic>> _eventController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<String>? _sseSub;
  HttpClient? _sseClient;
  Future<void>? _reconnectFuture;
  int? _reconnectGeneration;
  Completer<void> _reconnectCancellation = Completer<void>();
  bool _reconnectPending = false;
  int _rpcId = 0;

  @override
  bool get isRunning => process != null && !stopRequested;

  /// The phone number confirmed by signal-cli after linking or account list.
  /// Null until first successful registration check.
  String? get registeredPhone => _registeredPhone;

  /// SSE event stream — emits parsed envelope maps from inbound messages.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  /// Start the signal-cli daemon process and wait for health check.
  @override
  Future<void> start() => withLock(_start);

  Future<void> _start() async {
    if (stopRequested) throw StateError('SignalCliManager has been stopped');
    if (process != null) {
      throw StateError('SignalCliManager still owns a signal-cli process; stop it before restarting');
    }

    final gen = ++generation;
    log.info('Starting signal-cli (gen $gen): $executable on $host:$port');

    final args = ['daemon', '--http', '$host:$port', '--receive-mode', 'on-connection'];

    attachProcess(await spawnProcess(args), gen);

    if (!await waitForStartupHealth()) await abortFailedStartup();

    restartCount = 0;
    log.info('signal-cli started successfully (gen $gen)');

    // Connect SSE stream — relays inbound message events from signal-cli daemon.
    unawaited(_connectInitialSse(gen));
  }

  /// Stop the signal-cli process gracefully.
  @override
  Future<void> stop() {
    stopRequested = true;
    ++generation;
    _pendingLinkUri = null;
    _pendingLinkGeneration = null;
    _cancelReconnect();
    _sseClient?.close(force: true);
    beginIntentionalProcessTeardown(process);
    return withLock(_stop);
  }

  Future<void> _stop() async {
    await _settleReconnect();
    await _sseSub?.cancel();
    _sseSub = null;
    _sseClient?.close(force: true);
    _sseClient = null;
    await _eventController.close();

    final proc = process;
    if (proc == null) return;

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
    _cancelReconnect();
    _sseClient?.close(force: true);
    await _settleReconnect();
    final proc = process;
    beginIntentionalProcessTeardown(proc);

    if (proc != null) await resetOwnedProcess(proc);

    await _sseSub?.cancel();
    _sseSub = null;
    _sseClient?.close(force: true);
    _sseClient = null;

    if (!_eventController.isClosed) await _eventController.close();
    _eventController = StreamController<Map<String, dynamic>>.broadcast();

    stopRequested = false;
    wasPaired = false;
    _pendingLinkUri = null;
    _pendingLinkGeneration = null;
    _registeredPhone = null;
    restartCount = 0;
    _reconnectCancellation = Completer<void>();
    _reconnectPending = false;
  }

  // ---- JSON-RPC client methods ----

  /// Sends text and optional signal-cli UTF-16 [textStyles] via JSON-RPC.
  Future<void> sendMessage(
    String recipient,
    String text, {
    required bool isGroup,
    List<String> textStyles = const [],
  }) async {
    await _rpc('send', {
      'account': _registeredPhone ?? phoneNumber,
      if (isGroup) 'groupId': recipient else 'recipient': [recipient],
      'message': text,
      if (textStyles.isNotEmpty) 'textStyle': textStyles,
    });
  }

  /// Starts or stops a typing indicator for a direct recipient or group.
  Future<void> sendTyping(String recipient, {required bool isGroup, required bool isTyping}) async {
    await _rpc('sendTyping', {
      'account': _registeredPhone ?? phoneNumber,
      if (isGroup) 'groupId': recipient else 'recipient': recipient,
      if (!isTyping) 'stop': true,
    }, timeout: const Duration(seconds: 1));
  }

  /// Returns true if any Signal account is registered in signal-cli.
  ///
  /// Short-circuits to true if [wasPaired] is already set (e.g. finishLink
  /// just completed), since signal-cli may not reflect the new account in
  /// listAccounts until after finishLink's HTTP response is fully processed.
  ///
  /// Also caches the registered phone number in [_registeredPhone] — this
  /// handles the case where [phoneNumber] is a config placeholder.
  Future<bool> isAccountRegistered() async => await registrationState() == SignalRegistrationState.registered;

  /// Queries registration while preserving an indeterminate RPC result.
  Future<SignalRegistrationState> registrationState() async {
    if (wasPaired) return SignalRegistrationState.registered;
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
          wasPaired = true;
          _notifyRegistered(_registeredPhone!);
          return SignalRegistrationState.registered;
        }
      }
      return SignalRegistrationState.unregistered;
    } catch (e) {
      log.fine('isAccountRegistered check failed: $e');
      return SignalRegistrationState.unknown;
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
  Future<String?> getLinkDeviceUri({String deviceName = 'DartClaw'}) {
    if (stopRequested) return Future.value(null);
    final pendingUri = _pendingLinkUri;
    if (pendingUri != null && _pendingLinkGeneration == generation && !stopRequested) {
      return Future.value(pendingUri);
    }
    _pendingLinkUri = null;
    _pendingLinkGeneration = null;

    final linkGeneration = generation;
    final active = _linkFuture;
    if (active != null && _linkGeneration == linkGeneration) return active;

    late final Future<String?> operation;
    operation = _startDeviceLink(deviceName, linkGeneration).whenComplete(() {
      if (identical(_linkFuture, operation)) {
        _linkFuture = null;
        _linkGeneration = null;
      }
    });
    _linkFuture = operation;
    _linkGeneration = linkGeneration;
    return operation;
  }

  Future<String?> _startDeviceLink(String deviceName, int generation) async {
    try {
      final result = await _rpc('startLink', {});
      if (!_isCurrentLinkGeneration(generation)) return null;
      final uri = result is Map
          ? (result['deviceLinkUri'] as String? ?? result['uri'] as String?)
          : (result is String ? result : null);
      if (uri == null) return null;

      _pendingLinkUri = uri;
      _pendingLinkGeneration = generation;

      unawaited(_finishDeviceLink(uri, deviceName, generation));

      return uri;
    } catch (e) {
      log.warning('startLink failed', e);
      return null;
    }
  }

  Future<void> _finishDeviceLink(String uri, String deviceName, int generation) async {
    try {
      final result = await _rpc('finishLink', {'deviceLinkUri': uri, 'deviceName': deviceName}, timeout: _linkTimeout);
      if (!_isCurrentLink(generation, uri)) return;
      _pendingLinkUri = null;
      _pendingLinkGeneration = null;
      if (result is Map) {
        _registeredPhone = result['number'] as String? ?? result['account'] as String?;
      }
      log.info('finishLink completed: $result');
      _activateRegistration(_registeredPhone);
    } catch (e) {
      if (!_isCurrentLink(generation, uri)) return;
      final msg = e.toString();
      if (msg.contains('Connection closed') || msg.contains('IOException')) {
        log.fine('finishLink cancelled (connection closed)');
      } else {
        log.warning('finishLink failed', e);
      }
      _pendingLinkUri = null;
      _pendingLinkGeneration = null;
    }
  }

  bool _isCurrentLinkGeneration(int gen) => !stopRequested && gen == generation;

  bool _isCurrentLink(int generation, String uri) =>
      _isCurrentLinkGeneration(generation) && _pendingLinkGeneration == generation && _pendingLinkUri == uri;

  void _activateRegistration(String? phone) {
    wasPaired = true;
    if (phone != null && phone.isNotEmpty) {
      _registeredPhone = phone;
      _notifyRegistered(phone);
    }
    unawaited(_reconnectSse(queueIfActive: true, generation: generation));
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
      log.fine('Signal health check failed: $e');
      return false;
    }
  }

  @override
  Future<bool> defaultStartupProbe(int attempt) => healthCheck();

  // ---- SSE event stream ----

  Future<void> _connectInitialSse(int generation) async {
    if (!await _connectSse(generation) && _isCurrentSseGeneration(generation)) {
      await _reconnectSse(generation: generation);
    }
  }

  Future<bool> _connectSse(int generation) async {
    if (!_isCurrentSseGeneration(generation)) return false;

    try {
      _sseClient?.close(force: true);
      final client = HttpClient();
      _sseClient = client;
      final response =
          await (() async {
            final request = await client.getUrl(Uri.parse('$baseUrl/api/v1/events'));
            return request.close();
          }()).timeout(
            _sseHandshakeTimeout,
            onTimeout: () {
              client.close(force: true);
              throw TimeoutException('Signal SSE handshake timed out', _sseHandshakeTimeout);
            },
          );
      if (!_isCurrentSseGeneration(generation)) {
        client.close(force: true);
        return false;
      }
      if (response.statusCode >= 400) {
        client.close(force: true);
        throw HttpException('SSE endpoint returned HTTP ${response.statusCode}');
      }

      _sseSub = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => _handleSseLine(line, _eventController, log),
            onError: (Object e) {
              log.warning('SSE stream error', e);
              if (_isCurrentSseGeneration(generation)) {
                unawaited(_reconnectSse(queueIfActive: true, generation: generation));
              }
            },
            onDone: () {
              if (_isCurrentSseGeneration(generation)) {
                log.info('SSE stream closed, reconnecting');
                unawaited(_reconnectSse(queueIfActive: true, generation: generation));
              }
            },
          );
      return true;
    } catch (e) {
      log.warning('Failed to connect SSE', e);
      return false;
    }
  }

  Future<void> _reconnectSse({bool queueIfActive = false, int? generation}) {
    final reconnectGeneration = generation ?? this.generation;
    final active = _reconnectFuture;
    if (active != null) {
      if (queueIfActive && _reconnectGeneration == reconnectGeneration) {
        _reconnectPending = true;
      }
      return active;
    }

    _reconnectGeneration = reconnectGeneration;
    late final Future<void> operation;
    operation = _runReconnectSse(reconnectGeneration).whenComplete(() {
      if (identical(_reconnectFuture, operation)) {
        final reconnectAgain = _reconnectPending && _isCurrentSseGeneration(reconnectGeneration);
        _reconnectPending = false;
        _reconnectFuture = null;
        _reconnectGeneration = null;
        if (reconnectAgain) {
          unawaited(_reconnectSse(generation: reconnectGeneration));
        }
      }
    });
    _reconnectFuture = operation;
    return operation;
  }

  Future<void> _runReconnectSse(int generation) async {
    do {
      _reconnectPending = false;
      await _sseSub?.cancel();
      _sseSub = null;
      _sseClient?.close(force: true);
      _sseClient = null;
      await Future.any<void>([delay(const Duration(seconds: 2)), _reconnectCancellation.future]);
      if (!_isCurrentSseGeneration(generation)) return;
      if (!await _connectSse(generation)) {
        _reconnectPending = true;
      }
    } while (_reconnectPending && _isCurrentSseGeneration(generation));
  }

  bool _isCurrentSseGeneration(int gen) => !stopRequested && gen == generation;

  void _cancelReconnect() {
    if (!_reconnectCancellation.isCompleted) {
      _reconnectCancellation.complete();
    }
  }

  Future<void> _settleReconnect() async {
    final reconnect = _reconnectFuture;
    if (reconnect != null) {
      await reconnect;
    }
  }

  // ---- Crash recovery ----

  /// Starts the retry inline, so it runs synchronously to its first `await`
  /// and the reconnect bookkeeping observes it in the same turn as the exit.
  @override
  void scheduleRestart(Duration backoff, int generation) {
    unawaited(() async {
      await runScheduledRestart(backoff, generation);
    }());
  }

  // ---- JSON-RPC helper ----

  /// Send a JSON-RPC 2.0 request to signal-cli daemon.
  ///
  /// [timeout] overrides [_apiTimeout] for long-poll calls like `finishLink`.
  Future<dynamic> _rpc(String method, Map<String, dynamic> params, {Duration? timeout}) async {
    final client = HttpClient();
    final requestTimeout = timeout ?? _apiTimeout;
    try {
      return await (() async {
        final request = await client.postUrl(Uri.parse('$baseUrl/api/v1/rpc'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'jsonrpc': '2.0', 'id': (++_rpcId).toString(), 'method': method, 'params': params}));
        final response = await request.close();
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
      }()).timeout(
        requestTimeout,
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('signal-cli RPC $method timed out', requestTimeout);
        },
      );
    } finally {
      client.close();
    }
  }
}

void _handleSseLine(String line, StreamController<Map<String, dynamic>> eventController, Logger log) {
  if (!line.startsWith('data:')) return;
  final json = line.substring(5).trim();
  if (json.isEmpty) return;
  try {
    final parsed = jsonDecode(json);
    if (parsed is Map<String, dynamic>) {
      final params = parsed['params'] as Map<String, dynamic>?;
      final envelope = params?['envelope'] as Map<String, dynamic>?;
      if (envelope != null) {
        log.fine('SSE envelope received, dispatching to channel');
        eventController.add({'envelope': envelope});
      } else {
        eventController.add(parsed);
      }
    }
  } catch (e) {
    log.fine('Failed to parse SSE event: $e');
  }
}
