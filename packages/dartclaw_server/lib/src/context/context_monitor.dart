import 'package:logging/logging.dart';

final _log = Logger('ContextMonitor');

/// Tracks context token usage and triggers pre-compaction flush when
/// approaching the context window limit.
///
/// Call [update] with token counts from turn results. Check [shouldFlush]
/// after each turn to determine if a flush is needed.
class ContextMonitor {
  final int reserveTokens;

  int? _contextWindow;
  int? _lastContextTokens;
  bool _flushPending = false;

  ContextMonitor({this.reserveTokens = 20000});

  /// Update with latest token counts from bridge events.
  ///
  /// [contextWindow] — total context window size (from system init or config).
  /// [contextTokens] — current context usage (cumulative input tokens).
  void update({int? contextWindow, int? contextTokens}) {
    if (contextWindow != null) _contextWindow = contextWindow;
    if (contextTokens != null) _lastContextTokens = contextTokens;
  }

  /// Whether a pre-compaction flush should be triggered.
  ///
  /// True when context usage exceeds `contextWindow - reserveTokens` and
  /// no flush is already pending.
  bool get shouldFlush {
    final window = _contextWindow;
    final tokens = _lastContextTokens;
    if (window == null || tokens == null) return false;
    return tokens > window - reserveTokens && !_flushPending;
  }

  /// Mark that a flush turn has been initiated.
  void markFlushStarted() {
    _flushPending = true;
    _log.info('Pre-compaction flush started (tokens: $_lastContextTokens / $_contextWindow)');
  }

  /// Mark that a flush turn has completed (success or failure).
  /// Resets the pending flag for the next compaction cycle.
  void markFlushCompleted() {
    _flushPending = false;
    _log.info('Pre-compaction flush completed');
  }

  /// Current context window size (if known).
  int? get contextWindow => _contextWindow;

  /// Current context token usage (if known).
  int? get lastContextTokens => _lastContextTokens;

  /// Whether a flush is currently in progress.
  bool get isFlushPending => _flushPending;
}
