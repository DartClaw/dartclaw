/// Thrown when a turn cannot start because the agent is already busy.
class BusyTurnException implements Exception {
  final String message;
  final bool isSameSession; // true = same session busy, false = global busy (different session)

  BusyTurnException(this.message, {required this.isSameSession});

  @override
  String toString() => 'BusyTurnException: $message';
}
