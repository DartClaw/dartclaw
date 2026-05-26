/// Channel status for display on the settings page.
enum ChannelStatus {
  disabled('Disabled', 'status-badge-muted'),
  notRunning('Not running', 'status-badge-warning'),
  configured('Configured', 'status-badge-warning'),
  pairingNeeded('Pairing needed', 'status-badge-warning'),
  connectionError('Connection error', 'status-badge-error'),
  connected('Connected', 'status-badge-success'),
  reconnecting('Reconnecting', 'status-badge-warning');

  const ChannelStatus(this.label, this.badgeClass);
  final String label;
  final String badgeClass;

  /// The variant suffix of [badgeClass] (e.g. `'success'`, `'warning'`).
  String get badgeVariant => badgeClass.substring('status-badge-'.length);
}
