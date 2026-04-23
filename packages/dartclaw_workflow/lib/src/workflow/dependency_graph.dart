import 'dart:collection' show Queue;

/// Dependency-aware ordering for map/fan-out step collections.
///
/// Parses `id` and `dependencies` fields from collection items (Maps only).
/// Collections without any `dependencies` keys are treated as dependency-free.
///
/// Uses Kahn's algorithm for cycle detection and topological ordering.
class DependencyGraph {
  final List<dynamic> _items;

  /// Item ID → index mapping (only for items that declare an `id`).
  final Map<String, int> _idToIndex = {};

  /// Reverse mapping: index → item ID (only for items that declare an `id`).
  final Map<int, String> _indexToId = {};

  /// Index → list of dependency IDs.
  final Map<int, List<String>> _deps = {};

  /// Total number of items in the collection.
  final int _length;

  /// Whether the collection opted into dependency-aware scheduling.
  ///
  /// This is true when at least one item declares a `dependencies` field,
  /// including `dependencies: []` on root items.
  bool _dependencyAware = false;

  bool get isDependencyAware => _dependencyAware;

  /// Whether any item declares dependencies.
  bool get hasDependencies => _deps.isNotEmpty;

  DependencyGraph(List<dynamic> items) : _items = List<dynamic>.unmodifiable(items), _length = items.length {
    // First pass: build ID ↔ index maps.
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      if (item.containsKey('dependencies')) {
        _dependencyAware = true;
      }
      final id = item['id'];
      if (id is! String) continue;
      final normalizedId = id.trim();
      if (normalizedId.isEmpty || _idToIndex.containsKey(normalizedId)) continue;
      _idToIndex[normalizedId] = i;
      _indexToId[i] = normalizedId;
    }

    // Second pass: collect dependency declarations.
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      final depsRaw = item['dependencies'];
      if (depsRaw is! List) continue;
      final depIds = depsRaw
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
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
    if (!isDependencyAware) return;

    final seenIds = <String>{};
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item is! Map) {
        throw ArgumentError(
          'Dependency-aware collection item at index $i must be an object with `id` and `dependencies`.',
        );
      }

      final rawId = item['id'];
      if (rawId is! String || rawId.trim().isEmpty) {
        throw ArgumentError('Dependency-aware collection item at index $i is missing a non-empty `id`.');
      }
      final id = rawId.trim();
      if (!seenIds.add(id)) {
        throw ArgumentError('Dependency-aware collection contains duplicate id `$id`.');
      }

      if (!item.containsKey('dependencies')) {
        throw ArgumentError('Dependency-aware collection item `$id` at index $i is missing `dependencies`.');
      }
      if (item['dependencies'] is! List) {
        throw ArgumentError(
          'Dependency-aware collection item `$id` at index $i must provide `dependencies` as a list.',
        );
      }
    }

    final unknownDeps = unknownDependencyIds().toList()..sort();
    if (unknownDeps.isNotEmpty) {
      throw ArgumentError('Unknown dependency IDs: ${unknownDeps.join(', ')}');
    }
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
      final cycleNodes = inDegree.entries.where((e) => (e.value) > 0).map((e) => e.key).toList()..sort();

      // Build a simple path description.
      final path = _describeCycle(cycleNodes);
      throw ArgumentError('Circular dependency detected: $path');
    }
  }

  /// Returns dependency IDs that are declared but not present in the collection.
  Set<String> unknownDependencyIds() {
    final unknown = <String>{};
    for (final depIds in _deps.values) {
      for (final depId in depIds) {
        if (!_idToIndex.containsKey(depId)) {
          unknown.add(depId);
        }
      }
    }
    return unknown;
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
      final allSatisfied = myDeps.every(completed.contains);
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
