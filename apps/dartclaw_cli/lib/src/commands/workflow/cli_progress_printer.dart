import '../serve_command.dart' show WriteLine;

/// Formats and writes structured workflow progress lines to a [WriteLine] sink.
///
/// Output is human-readable and machine-parseable:
/// ```
/// [workflow] Starting: Spec & Implement (6 steps)
/// [step 1/6] research: Research & Design — running (claude)
/// [step 1/6] research: completed (45s, 12K tokens)
/// [workflow] Completed: 6/6 steps (4m 32s, 89K tokens)
/// ```
class CliProgressPrinter {
  final int totalSteps;
  final String workflowName;
  final WriteLine _writeLine;
  final Stopwatch _stopwatch = Stopwatch();

  CliProgressPrinter({
    required this.totalSteps,
    required this.workflowName,
    required WriteLine writeLine,
  }) : _writeLine = writeLine;

  void workflowStarted() {
    _stopwatch.start();
    _writeLine('[workflow] Starting: $workflowName ($totalSteps steps)');
  }

  void stepRunning(int stepIndex, String stepId, String stepName, String? provider) {
    final providerSuffix = provider != null ? ' ($provider)' : '';
    _writeLine('[step ${stepIndex + 1}/$totalSteps] $stepId: $stepName — running$providerSuffix');
  }

  void stepReview(int stepIndex, String stepId) {
    _writeLine('[step ${stepIndex + 1}/$totalSteps] $stepId: review (auto-accepted)');
  }

  void stepCompleted(int stepIndex, String stepId, Duration duration, int tokens) {
    final durationStr = _formatDuration(duration);
    final tokenStr = _formatTokens(tokens);
    _writeLine('[step ${stepIndex + 1}/$totalSteps] $stepId: completed ($durationStr, $tokenStr)');
  }

  void stepFailed(int stepIndex, String stepId, String? error) {
    _writeLine('[step ${stepIndex + 1}/$totalSteps] $stepId: '
        'failed${error != null ? ' — $error' : ''}');
  }

  void workflowCompleted(int completedSteps, int tokens) {
    final elapsed = _formatDuration(_stopwatch.elapsed);
    final tokenStr = _formatTokens(tokens);
    _writeLine('[workflow] Completed: $completedSteps/$totalSteps steps ($elapsed, $tokenStr)');
  }

  void workflowFailed(int completedSteps, String? error) {
    _writeLine('[workflow] Failed at step ${completedSteps + 1}/$totalSteps'
        '${error != null ? ': $error' : ''}');
  }

  void workflowPaused(int completedSteps, String? reason) {
    _writeLine('[workflow] Paused at step ${completedSteps + 1}/$totalSteps'
        '${reason != null ? ': $reason' : ''}');
  }

  void workflowCancelling() {
    _writeLine('[workflow] Cancelling...');
  }

  String _formatDuration(Duration d) {
    if (d.inMinutes > 0) {
      final secs = d.inSeconds % 60;
      return '${d.inMinutes}m ${secs}s';
    }
    return '${d.inSeconds}s';
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(0)}K tokens';
    return '$tokens tokens';
  }
}
