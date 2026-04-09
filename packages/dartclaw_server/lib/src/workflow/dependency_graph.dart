import 'dart:collection' show Queue;

/// Dependency-aware ordering for map/fan-out step collections.
///
/// Parses `id` and `dependencies` fields from collection items (Maps only).
/// Items without these fields are treated as independent (no dependencies).
///
/// Uses Kahn's algorithm for cycle detection and topological ordering.
class DependencyGraph {
  /// Item ID → index mapping (only for items that declare an `id`).
  final Map<String, int> _idToIndex = {};

  /// Reverse mapping: index → item ID (only for items that declare an `id`).
  final Map<int, String> _indexToId = {};

  /// Index → list of dependency IDs.
  final Map<int, List<String>> _deps = {};

  /// Total number of items in the collection.
  final int _length;

  /// Whether any item declares dependencies.
  bool get hasDependencies => _deps.isNotEmpty;

  DependencyGraph(List<dynamic> items) : _length = items.length {
    // First pass: build ID ↔ index maps.
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is Map) {
        final id = item['id'];
        if (id is String && id.isNotEmpty) {
          _idToIndex[id] = i;
          _indexToId[i] = id;
        }
      }
    }

    // Second pass: collect dependency declarations.
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      final depsRaw = item['dependencies'];
      if (depsRaw is! List) continue;
      final depIds = depsRaw.whereType<String>().toList();
      if (depIds.isNotEmpty) {
        _deps[i] = depIds;
      }
    }
  }

  /// Validates the graph for cycles using Kahn's algorithm.
  ///
  /// Throws [ArgumentError] if a cycle is detected, with a message
  /// describing the cycle path (e.g. "Circular dependency detected: s01 → s03 → s01").
  void validate() {
    if (!hasDependencies) return;

    // Build in-degree count for each item that has a declared ID.
    final inDegree = <String, int>{};
    for (final id in _idToIndex.keys) {
      inDegree[id] = 0;
    }

    // Count incoming edges.
    for (final entry in _deps.entries) {
      final itemId = _indexToId[entry.key];
      if (itemId == null) continue; // Item without ID -- skip cycle check.
      for (final depId in entry.value) {
        if (_idToIndex.containsKey(depId)) {
          inDegree[itemId] = (inDegree[itemId] ?? 0) + 1;
        }
      }
    }

    // Kahn's: start with all zero-in-degree nodes.
    final queue = Queue<String>();
    for (final entry in inDegree.entries) {
      if (entry.value == 0) queue.add(entry.key);
    }

    var processed = 0;
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      processed++;

      // For each item that depends on `current`, decrement its in-degree.
      for (final entry in _deps.entries) {
        if (!entry.value.contains(current)) continue;
        final dependentId = _indexToId[entry.key];
        if (dependentId == null) continue;
        inDegree[dependentId] = (inDegree[dependentId] ?? 0) - 1;
        if (inDegree[dependentId] == 0) {
          queue.add(dependentId);
        }
      }
    }

    // If we processed fewer nodes than exist, there's a cycle.
    if (processed < inDegree.length) {
      // Find the cycle members.
      final cycleNodes = inDegree.entries
          .where((e) => (e.value) > 0)
          .map((e) => e.key)
          .toList()
        ..sort();

      // Build a simple path description.
      final path = _describeCycle(cycleNodes);
      throw ArgumentError('Circular dependency detected: $path');
    }
  }

  /// Returns indices of items that are ready to dispatch given [completed] item IDs.
  ///
  /// An item is ready when all its declared dependencies are in [completed].
  /// Items with no dependency declarations are always ready.
  ///
  /// Only returns indices NOT already in [completed] (by index) -- callers
  /// track completion by ID in [completed] but need index to dispatch.
  List<int> getReady(Set<String> completed) {
    final ready = <int>[];
    for (var i = 0; i < _length; i++) {
      final myDeps = _deps[i];
      if (myDeps == null || myDeps.isEmpty) {
        ready.add(i);
        continue;
      }
      final allSatisfied = myDeps.every(
        (depId) => !_idToIndex.containsKey(depId) || completed.contains(depId),
      );
      if (allSatisfied) ready.add(i);
    }
    return ready;
  }

  /// Builds a human-readable cycle description from [cycleNodes].
  String _describeCycle(List<String> cycleNodes) {
    if (cycleNodes.isEmpty) return '(unknown cycle)';
    return '${cycleNodes.join(' → ')} → ${cycleNodes.first}';
  }
}
