/// Configuration for the live-reload trigger.
class ReloadConfig {
  /// Reload trigger mode.
  ///
  /// - `'signal'` (default): reload on `SIGUSR1` only.
  /// - `'auto'`: reload on config file changes (file-watch + SIGUSR1 fallback).
  /// - `'off'`: no reload triggers enabled.
  final String mode;

  /// Debounce delay in milliseconds for file-watch mode.
  ///
  /// Rapid successive file saves are coalesced into a single reload.
  /// Minimum: 100 ms. Default: 500 ms.
  final int debounceMs;

  const ReloadConfig({this.mode = 'signal', this.debounceMs = 500});

  const ReloadConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ReloadConfig && mode == other.mode && debounceMs == other.debounceMs;

  @override
  int get hashCode => Object.hash(mode, debounceMs);
}

/// Configuration for the gateway subsystem.
class GatewayConfig {
  final String authMode;
  final String? token;
  final bool hsts;
  final ReloadConfig reload;

  const GatewayConfig({
    this.authMode = 'token',
    this.token,
    this.hsts = false,
    this.reload = const ReloadConfig.defaults(),
  });

  /// Default configuration.
  const GatewayConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GatewayConfig &&
          authMode == other.authMode &&
          token == other.token &&
          hsts == other.hsts &&
          reload == other.reload;

  @override
  int get hashCode => Object.hash(authMode, token, hsts, reload);
}
