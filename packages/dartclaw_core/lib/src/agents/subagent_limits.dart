import 'package:logging/logging.dart';

/// Enforces concurrency, depth, and children limits for sub-agent spawning.
class SubagentLimits {
  static final _log = Logger('SubagentLimits');

  final int maxConcurrent;
  final int maxSpawnDepth;
  final int maxChildrenPerAgent;

  final Map<String, int> _childrenCount = {};
  int _totalActive = 0;

  SubagentLimits({this.maxConcurrent = 3, this.maxSpawnDepth = 1, this.maxChildrenPerAgent = 2});

  int get totalActive => _totalActive;

  /// Check if a new agent can be spawned given current state.
  bool canSpawn({required String parentAgentId, required int currentDepth}) {
    if (_totalActive >= maxConcurrent) {
      _log.warning('Cannot spawn: at max concurrent ($maxConcurrent)');
      return false;
    }
    if (currentDepth >= maxSpawnDepth) {
      _log.warning('Cannot spawn: at max depth ($maxSpawnDepth)');
      return false;
    }
    final children = _childrenCount[parentAgentId] ?? 0;
    if (children >= maxChildrenPerAgent) {
      _log.warning('Cannot spawn: agent "$parentAgentId" at max children ($maxChildrenPerAgent)');
      return false;
    }
    return true;
  }

  /// Record that a new agent was spawned.
  void recordSpawn(String parentAgentId) {
    _totalActive++;
    _childrenCount[parentAgentId] = (_childrenCount[parentAgentId] ?? 0) + 1;
  }

  /// Record that an agent completed/stopped.
  void recordComplete(String parentAgentId) {
    _totalActive = (_totalActive - 1).clamp(0, maxConcurrent);
    final current = _childrenCount[parentAgentId] ?? 0;
    if (current <= 1) {
      _childrenCount.remove(parentAgentId);
    } else {
      _childrenCount[parentAgentId] = current - 1;
    }
  }

  /// Reset all tracking state.
  void reset() {
    _totalActive = 0;
    _childrenCount.clear();
  }
}
