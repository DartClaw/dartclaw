import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

final _log = Logger('ContextMonitor');

/// Tracks context token usage and triggers pre-compaction flush when
/// approaching the context window limit.
///
/// Call [update] with token counts from turn results. Check [shouldFlush]
/// after each turn to determine if a flush is needed. Check [checkThreshold]
/// with a session ID to emit a one-shot context warning per session when
/// usage exceeds [warningThreshold]%.
///
/// This monitor is typically shared across all [TurnRunner] instances in the
/// harness pool. Warning state is tracked per session via [_warnedSessions].
class ContextMonitor implements Reconfigurable {
  int reserveTokens;

  /// Warning threshold as an integer percentage (50–99). When context usage
  /// exceeds this percentage, [checkThreshold] returns `true` once per session.
  ///
  /// Non-final to allow live config updates without restart.
  int warningThreshold;

  /// When `true`, suppresses the [shouldFlush] heuristic entirely.
  ///
  /// This remains a useful default for single-harness deployments. Callers
  /// managing heterogeneous runner pools should use
  /// [shouldFlushForCompactionSignal] so the decision is resolved per runner
  /// instead of via shared mutable state.
  bool compactionSignalAvailable = false;

  int? _contextWindow;
  int? _lastContextTokens;
  bool _flushPending = false;
  final Set<String> _warnedSessions = {};

  // Per-compaction-cycle flush dedup state.
  int _compactionCycleId = 0;
  int _lastFlushCycleId = -1;
  String? _lastFlushHash;

  ContextMonitor({this.reserveTokens = 20000, this.warningThreshold = 80});

  @override
  Set<String> get watchKeys => const {'context.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    reserveTokens = delta.current.context.reserveTokens;
    warningThreshold = delta.current.context.warningThreshold;
    _log.info('ContextMonitor reconfigured (reserveTokens: $reserveTokens, warningThreshold: $warningThreshold%)');
  }

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
  /// Returns `false` unconditionally when [compactionSignalAvailable] is `true`
  /// (the harness delivers a deterministic signal; the heuristic is not needed).
  ///
  /// Otherwise: `true` when context usage exceeds `contextWindow - reserveTokens`
  /// and no flush is already pending.
  bool shouldFlushForCompactionSignal({required bool compactionSignalAvailable}) {
    if (compactionSignalAvailable) return false;
    final window = _contextWindow;
    final tokens = _lastContextTokens;
    if (window == null || tokens == null) return false;
    return tokens > window - reserveTokens && !_flushPending;
  }

  /// Backward-compatible getter for callers that use the shared default flag.
  bool get shouldFlush => shouldFlushForCompactionSignal(compactionSignalAvailable: compactionSignalAvailable);

  /// Increments the compaction cycle counter.
  ///
  /// Called when a compaction completes (via [CompactionCompletedEvent]).
  /// Enables the next flush by advancing the cycle ID past [_lastFlushCycleId].
  void onCompactionCompleted() {
    _compactionCycleId++;
    _log.fine('Compaction cycle advanced to $_compactionCycleId');
  }

  /// Returns `true` when the flush should be skipped.
  ///
  /// Skips if this compaction cycle has already been flushed, or if the
  /// message content hash matches the previous flush (SHA-256 dedup).
  bool shouldSkipFlush(String messageHash) {
    if (_lastFlushCycleId == _compactionCycleId) return true;
    if (_lastFlushHash == messageHash) return true;
    return false;
  }

  /// Records that a flush was executed with the given [messageHash].
  ///
  /// Updates [_lastFlushCycleId] and [_lastFlushHash] to prevent redundant
  /// flushes within the same compaction cycle or with identical content.
  void markFlushed(String messageHash) {
    _lastFlushCycleId = _compactionCycleId;
    _lastFlushHash = messageHash;
  }

  /// Current compaction cycle counter (starts at 0, incremented by [onCompactionCompleted]).
  int get compactionCycleId => _compactionCycleId;

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

  /// Checks whether context usage has crossed the warning threshold for
  /// the given [sessionId].
  ///
  /// Returns `true` exactly once per session when usage first exceeds
  /// [warningThreshold]% of the context window. Subsequent calls for the
  /// same session return `false` even if usage continues to rise.
  ///
  /// When [sessionId] is null, uses a synthetic key so the one-shot
  /// behavior still works (returns true at most once for null callers).
  bool checkThreshold({String? sessionId}) {
    final key = sessionId ?? '_default';
    if (_warnedSessions.contains(key)) return false;
    final window = _contextWindow;
    final tokens = _lastContextTokens;
    if (window == null || tokens == null || window == 0) return false;

    final usage = (tokens * 100) ~/ window;
    if (usage >= warningThreshold) {
      _warnedSessions.add(key);
      _log.info('Context warning threshold reached for $key: $usage% (threshold: $warningThreshold%)');
      return true;
    }
    return false;
  }

  /// Current context window size (if known).
  int? get contextWindow => _contextWindow;

  /// Current context token usage (if known).
  int? get lastContextTokens => _lastContextTokens;

  /// Whether a flush is currently in progress.
  bool get isFlushPending => _flushPending;

  /// Current usage as an integer percentage (0–100), or null if unknown.
  int? get usagePercent {
    final window = _contextWindow;
    final tokens = _lastContextTokens;
    if (window == null || tokens == null || window == 0) return null;
    return (tokens * 100) ~/ window;
  }

  /// Whether the context warning has been emitted for the given [sessionId].
  ///
  /// When [sessionId] is null, checks the synthetic `_default` key.
  bool warningEmitted({String? sessionId}) => _warnedSessions.contains(sessionId ?? '_default');
}
