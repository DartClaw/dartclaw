/// Yields to the event loop [turns] times using `Duration.zero` delays.
Future<void> flushAsync([int turns = 2]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
