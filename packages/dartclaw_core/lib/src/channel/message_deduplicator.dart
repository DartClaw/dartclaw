import 'dart:collection';

import 'package:logging/logging.dart';

/// Bounded FIFO set that prevents duplicate message processing.
///
/// When a message arrives via multiple ingest paths (e.g., both webhook
/// and Pub/Sub), the deduplicator ensures it is processed exactly once.
/// Keyed on message resource name (e.g., `spaces/{space}/messages/{id}`).
///
/// First-seen wins: [tryProcess] returns `true` the first time a resource
/// name is seen, `false` on subsequent calls. The oldest-inserted entry is
/// evicted when [capacity] is exceeded (insertion-order FIFO, not
/// access-order LRU — sufficient for the dedup use case where duplicates
/// arrive within seconds of each other).
///
/// Placed in `dartclaw_core` for cross-channel reuse.
class MessageDeduplicator {
  static final _log = Logger('MessageDeduplicator');

  /// Default capacity — ~10 minutes of high-volume conversation.
  static const defaultCapacity = 1000;

  final int _capacity;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  /// Creates a deduplicator with the given [capacity].
  ///
  /// [capacity] is clamped to a minimum of 1. Defaults to [defaultCapacity] (1000).
  MessageDeduplicator({int capacity = defaultCapacity}) : _capacity = capacity < 1 ? 1 : capacity;

  /// Attempts to process a message with the given [resourceName].
  ///
  /// Returns `true` if this is the first time this resource name has been
  /// seen (the caller should process it). Returns `false` if it's a
  /// duplicate (the caller should skip it).
  bool tryProcess(String resourceName) {
    if (_seen.contains(resourceName)) {
      _log.fine('Duplicate message skipped: $resourceName');
      return false;
    }

    // Evict oldest entry if at capacity.
    if (_seen.length >= _capacity) {
      _seen.remove(_seen.first);
    }

    _seen.add(resourceName);
    return true;
  }

  /// Number of resource names currently tracked.
  int get length => _seen.length;

  /// Maximum number of entries before FIFO eviction.
  int get capacity => _capacity;

  /// Removes all tracked resource names.
  void clear() => _seen.clear();
}
