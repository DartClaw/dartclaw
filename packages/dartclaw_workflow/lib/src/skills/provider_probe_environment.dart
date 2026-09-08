/// Environment prepared for one provider CLI probe.
///
/// [dispose] releases any temporary provider state after the probe settles.
/// Persistent and caller-owned environments use the default no-op disposal.
final class ProviderProbeEnvironment {
  /// Variables passed to the provider process.
  final Map<String, String> environment;

  final Future<void> Function()? _dispose;
  bool _disposed = false;

  /// Creates a probe environment with optional async cleanup.
  new(Map<String, String> environment, {Future<void> Function()? dispose})
    : environment = Map.unmodifiable(environment),
      _dispose = dispose;

  /// Releases temporary state once. Safe to call repeatedly.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _dispose?.call();
  }
}
