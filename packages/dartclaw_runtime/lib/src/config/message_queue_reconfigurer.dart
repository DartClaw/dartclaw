import 'package:dartclaw_core/dartclaw_core.dart' show MessageQueue;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Applies a reloaded `concurrency.max_parallel_turns` to the channel
/// [MessageQueue], which keeps its own copy of the cap.
///
/// Core's queue stays config-agnostic; this hop carries the server config key
/// across, as `SessionLockManager` does for the shared turn lock.
class MessageQueueReconfigurer implements Reconfigurable {
  new(this._queue);

  final MessageQueue _queue;

  @override
  Set<String> get watchKeys => const {'server.*'};

  @override
  void reconfigure(ConfigDelta delta) => _queue.maxConcurrentTurns = delta.current.server.maxParallelTurns;
}
