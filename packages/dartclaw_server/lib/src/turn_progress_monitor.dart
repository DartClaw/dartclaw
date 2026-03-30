import 'dart:async';

/// Detects silent turn stalls by resetting a timer on progress events.
class TurnProgressMonitor {
  final Duration stallTimeout;
  final void Function(Duration stallTimeout) onStall;

  Timer? _stallTimer;
  bool _running = false;

  TurnProgressMonitor({required this.stallTimeout, required this.onStall});

  void start() {
    _running = true;
    _resetTimer();
  }

  void recordProgress() {
    if (!_running) {
      return;
    }
    _resetTimer();
  }

  void stop() {
    _running = false;
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _resetTimer() {
    _stallTimer?.cancel();
    if (stallTimeout <= Duration.zero) {
      return;
    }
    _stallTimer = Timer(stallTimeout, () {
      if (_running) {
        onStall(stallTimeout);
      }
    });
  }
}
