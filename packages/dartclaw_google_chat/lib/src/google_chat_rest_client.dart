import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Default Google Chat REST API base URL.
const chatApiBase = 'https://chat.googleapis.com/v1';

final _spaceNamePattern = RegExp(r'^spaces/[^/]+$');
final _messageNamePattern = RegExp(r'^spaces/[^/]+/messages/[^/]+$');
final _resourceNamePattern = RegExp(r'^spaces/[^/]+/messages/[^/]+/attachments/[^/]+$');

/// Exception thrown when the Google Chat API returns an unusable response.
class GoogleChatApiException implements Exception {
  /// Human-readable error message.
  final String message;

  /// Optional HTTP status associated with the failure.
  final int? statusCode;

  /// Optional lower-level cause object.
  final Object? cause;

  /// Creates a Google Chat API exception.
  const GoogleChatApiException(this.message, {this.statusCode, this.cause});

  @override
  String toString() => 'GoogleChatApiException($message${statusCode == null ? '' : ', statusCode: $statusCode'})';
}

/// Thin authenticated client for Google Chat REST endpoints used by DartClaw.
class GoogleChatRestClient {
  final http.Client _client;
  final String _apiBase;
  final Future<void> Function(Duration) _delay;
  final Map<String, _SpaceWriteQueue> _spaceQueues = {};
  final Logger _log = Logger('GoogleChatRestClient');

  /// Creates a REST client backed by an authenticated HTTP client.
  GoogleChatRestClient({required http.Client authClient, String? apiBase, Future<void> Function(Duration)? delay})
    : _client = authClient,
      _apiBase = (apiBase ?? chatApiBase).replaceFirst(RegExp(r'/+$'), ''),
      _delay = delay ?? Future.delayed;

  /// Verifies that the authenticated client can successfully call the Chat API.
  Future<void> testConnection() async {
    final uri = Uri.parse('$_apiBase/spaces?pageSize=1');
    try {
      final response = await _client.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Google Chat API test connection failed with HTTP ${response.statusCode}');
        throw GoogleChatApiException('Google Chat API test connection failed', statusCode: response.statusCode);
      }
    } on GoogleChatApiException {
      rethrow;
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat API test connection request failed', error, stackTrace);
      throw GoogleChatApiException('Google Chat API test connection request failed', cause: error);
    }
  }

  /// Sends a plain-text message to [spaceName] and returns its resource name.
  Future<String?> sendMessage(String spaceName, String text) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat send for invalid space name "$spaceName"');
      return null;
    }

    return _queueFor(spaceName).enqueue<String?>(() async {
      try {
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'text': text}),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat send failed for $spaceName with HTTP ${response.statusCode}');
          return null;
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          _log.warning('Google Chat send returned invalid JSON for $spaceName');
          return null;
        }
        return decoded['name'] as String?;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat send failed for $spaceName', error, stackTrace);
        return null;
      }
    });
  }

  /// Sends a structured Cards v2 message to [spaceName].
  Future<String?> sendCard(String spaceName, Map<String, dynamic> cardPayload) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat card send for invalid space name "$spaceName"');
      return null;
    }

    return _queueFor(spaceName).enqueue<String?>(() async {
      try {
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(cardPayload),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat card send failed for $spaceName with HTTP ${response.statusCode}');
          return null;
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          _log.warning('Google Chat card send returned invalid JSON for $spaceName');
          return null;
        }
        return decoded['name'] as String?;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat card send failed for $spaceName', error, stackTrace);
        return null;
      }
    });
  }

  /// Edits an existing Google Chat message in place.
  Future<bool> editMessage(String messageName, String newText) async {
    if (!_messageNamePattern.hasMatch(messageName)) {
      _log.warning('Rejected Google Chat edit for invalid message name "$messageName"');
      return false;
    }

    final messageIndex = messageName.indexOf('/messages/');
    final spaceName = messageName.substring(0, messageIndex);

    return _queueFor(spaceName).enqueue<bool>(() async {
      try {
        final response = await _client.patch(
          Uri.parse('$_apiBase/$messageName?updateMask=text'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'text': newText}),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat edit failed for $messageName with HTTP ${response.statusCode}');
          return false;
        }
        return true;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat edit failed for $messageName', error, stackTrace);
        return false;
      }
    });
  }

  /// Downloads binary attachment data for a Google Chat media resource.
  Future<List<int>?> downloadMedia(String resourceName) async {
    if (!_resourceNamePattern.hasMatch(resourceName)) {
      _log.warning('Rejected Google Chat media download for invalid resource "$resourceName"');
      return null;
    }

    try {
      final response = await _client.get(Uri.parse('$_apiBase/media/$resourceName?alt=media'));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Google Chat media download failed for $resourceName with HTTP ${response.statusCode}');
        return null;
      }
      return response.bodyBytes;
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat media download failed for $resourceName', error, stackTrace);
      return null;
    }
  }

  /// Flushes pending writes and closes the underlying HTTP client.
  Future<void> close() async {
    final flushes = _spaceQueues.values.map((queue) => queue.flush()).toList(growable: false);
    _spaceQueues.clear();
    try {
      await Future.wait(flushes).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _log.warning('Timed out waiting for Google Chat write queues to flush');
    } finally {
      _client.close();
    }
  }

  _SpaceWriteQueue _queueFor(String spaceName) {
    return _spaceQueues.putIfAbsent(spaceName, () => _SpaceWriteQueue(delay: _delay));
  }
}

class _SpaceWriteQueue {
  final Future<void> Function(Duration) _delay;
  final Queue<_QueuedWrite<dynamic>> _pending = Queue<_QueuedWrite<dynamic>>();
  Completer<void> _idle = Completer<void>()..complete();
  bool _draining = false;

  _SpaceWriteQueue({required Future<void> Function(Duration) delay}) : _delay = delay;

  Future<T> enqueue<T>(Future<T> Function() write) {
    if (_pending.isEmpty && _idle.isCompleted) {
      _idle = Completer<void>();
    }
    final completer = Completer<T>();
    _pending.add(_QueuedWrite<T>(run: write, completer: completer));
    if (!_draining) {
      unawaited(_drain());
    }
    return completer.future;
  }

  Future<void> flush() async {
    if (_pending.isEmpty && !_draining) {
      return;
    }
    await _idle.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final entry = _pending.removeFirst();
        try {
          final result = await entry.run();
          entry.completer.complete(result);
        } catch (error, stackTrace) {
          entry.completer.completeError(error, stackTrace);
        }
        if (_pending.isNotEmpty) {
          await _delay(const Duration(seconds: 1));
        }
      }
    } finally {
      _draining = false;
      if (!_idle.isCompleted) {
        _idle.complete();
      }
    }
  }
}

class _QueuedWrite<T> {
  final Future<T> Function() run;
  final Completer<T> completer;

  const _QueuedWrite({required this.run, required this.completer});
}
