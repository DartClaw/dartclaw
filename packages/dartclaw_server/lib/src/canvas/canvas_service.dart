import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'canvas_state.dart';

/// In-memory canvas state + per-session SSE broadcast.
class CanvasService {
  /// Default maximum HTML size: 512 KB.
  static const int defaultMaxHtmlBytes = 512 * 1024;

  final Map<String, CanvasState> _states = {};
  final Map<String, Set<StreamController<List<int>>>> _viewers = {};
  final Map<String, CanvasShareToken> _tokens = {};
  final Random _random;
  final int _maxConnections;
  final int _maxHtmlBytes;

  CanvasService({Random? random, int maxConnections = 50, int maxHtmlBytes = defaultMaxHtmlBytes})
    : _random = random ?? Random.secure(),
      _maxConnections = maxConnections,
      _maxHtmlBytes = maxHtmlBytes;

  void push(String sessionKey, String htmlFragment) {
    final key = _normalizeSessionKey(sessionKey);
    if (utf8.encode(htmlFragment).length > _maxHtmlBytes) {
      throw ArgumentError('HTML fragment exceeds maximum size of $_maxHtmlBytes bytes');
    }
    final state = (_states[key] ?? const CanvasState()).copyWith(currentHtml: htmlFragment);
    _states[key] = state;
    _broadcast(key, 'canvas_update', {'html': htmlFragment, 'visible': state.visible});
  }

  void clear(String sessionKey) {
    final key = _normalizeSessionKey(sessionKey);
    final state = (_states[key] ?? const CanvasState()).copyWith(clearCurrentHtml: true);
    _states[key] = state;
    _broadcast(key, 'canvas_clear', {'visible': state.visible});
  }

  void setVisible(String sessionKey, bool visible) {
    final key = _normalizeSessionKey(sessionKey);
    final state = (_states[key] ?? const CanvasState()).copyWith(visible: visible);
    _states[key] = state;
    _broadcast(key, 'canvas_visible', {'visible': visible});
  }

  CanvasState? getState(String sessionKey) {
    final key = _normalizeSessionKey(sessionKey);
    return _states[key];
  }

  StreamController<List<int>> subscribe(String sessionKey) {
    final key = _normalizeSessionKey(sessionKey);
    final viewers = _viewers.putIfAbsent(key, () => <StreamController<List<int>>>{});
    if (viewers.length >= _maxConnections) {
      throw StateError('Canvas connection limit reached for session "$key"');
    }
    final controller = StreamController<List<int>>();
    viewers.add(controller);
    controller.onCancel = () {
      viewers.remove(controller);
      if (viewers.isEmpty) {
        _viewers.remove(key);
      }
    };
    return controller;
  }

  CanvasShareToken createShareToken(
    String sessionKey, {
    CanvasPermission permission = CanvasPermission.interact,
    Duration ttl = const Duration(hours: 8),
    String? label,
  }) {
    if (ttl <= Duration.zero) {
      throw ArgumentError.value(ttl, 'ttl', 'TTL must be greater than zero');
    }

    final key = _normalizeSessionKey(sessionKey);
    // Lazy cleanup of expired tokens to prevent unbounded memory growth.
    _tokens.removeWhere((_, t) => t.isExpired);

    final token = _generateUniqueToken();
    final shareToken = CanvasShareToken(
      token: token,
      sessionKey: key,
      permission: permission,
      expiresAt: DateTime.now().add(ttl),
      label: label,
    );

    _tokens[token] = shareToken;
    final state = _states[key] ?? const CanvasState();
    final activeTokens = state.activeTokens.where((entry) => !entry.isExpired).toList(growable: true)..add(shareToken);
    _states[key] = state.copyWith(activeTokens: List.unmodifiable(activeTokens));
    return shareToken;
  }

  CanvasShareToken? validateShareToken(String token) {
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) return null;

    final shareToken = _tokens[normalizedToken];
    if (shareToken == null) return null;
    if (shareToken.isExpired) {
      revokeShareToken(normalizedToken);
      return null;
    }
    return shareToken;
  }

  void revokeShareToken(String token) {
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) return;

    final removed = _tokens.remove(normalizedToken);
    if (removed == null) return;

    final state = _states[removed.sessionKey];
    if (state == null) return;
    final activeTokens = state.activeTokens
        .where((entry) => !entry.isExpired && entry.token != removed.token)
        .toList(growable: false);
    _states[removed.sessionKey] = state.copyWith(activeTokens: List.unmodifiable(activeTokens));
  }

  int viewerCountForSession(String sessionKey) {
    final key = _normalizeSessionKey(sessionKey);
    return _viewers[key]?.length ?? 0;
  }

  int get tokenCount => _tokens.length;
  int get maxConnections => _maxConnections;

  Future<void> dispose() async {
    for (final viewers in _viewers.values) {
      for (final controller in viewers) {
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      }
    }
    _viewers.clear();
    _states.clear();
    _tokens.clear();
  }

  void _broadcast(String sessionKey, String event, Map<String, dynamic> payload) {
    final viewers = _viewers[sessionKey];
    if (viewers == null || viewers.isEmpty) return;

    final bytes = utf8.encode('event: $event\ndata: ${jsonEncode(payload)}\n\n');
    final stale = <StreamController<List<int>>>[];
    for (final controller in viewers) {
      if (controller.isClosed) {
        stale.add(controller);
        continue;
      }
      try {
        controller.add(bytes);
      } catch (_) {
        stale.add(controller);
      }
    }
    for (final controller in stale) {
      viewers.remove(controller);
    }
    if (viewers.isEmpty) {
      _viewers.remove(sessionKey);
    }
  }

  String _generateUniqueToken() {
    while (true) {
      final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
      final token = base64UrlEncode(bytes);
      if (!_tokens.containsKey(token)) return token;
    }
  }

  static String _normalizeSessionKey(String sessionKey) {
    final key = sessionKey.trim();
    if (key.isEmpty) {
      throw ArgumentError.value(sessionKey, 'sessionKey', 'Session key must not be empty');
    }
    return key;
  }
}
