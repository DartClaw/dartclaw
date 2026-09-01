/// Everything a surface needs to present a [ChannelStatus].
///
/// The fields are deliberately independent. A consumer must never infer the
/// dot, banner, policy hint or connected-only action from the badge suffix, the
/// label string, or a boolean assembled elsewhere — three states share
/// `status-badge-warning` while differing in every other field, and `Disabled`
/// is not "not running".
typedef ChannelStatusPresentation = ({
  String label,
  String badgeClass,
  String dotVariant,
  String? stateBannerVariant,
  String? stateBannerText,
  String? dmPolicyHint,
  bool connected,
});

/// Channel status for display on the settings page and the channel detail page.
enum ChannelStatus {
  disabled,
  notRunning,
  configured,
  pairingNeeded,
  connectionError,
  connected,
  reconnecting;

  /// The single source for every status-derived value on every channel surface.
  ///
  /// Exhaustive over the enum with no wildcard arm: adding a status is a
  /// compile error until its presentation is stated here.
  ChannelStatusPresentation get presentation => switch (this) {
    ChannelStatus.disabled => (
      label: 'Disabled',
      badgeClass: 'status-badge-muted',
      dotVariant: 'idle',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
    ChannelStatus.notRunning => (
      label: 'Not running',
      badgeClass: 'status-badge-warning',
      dotVariant: 'idle',
      stateBannerVariant: 'warning',
      stateBannerText: 'Channel is not running. Policy changes apply when it starts.',
      dmPolicyHint: 'DM allowlist changes apply when the channel starts.',
      connected: false,
    ),
    ChannelStatus.configured => (
      label: 'Configured',
      badgeClass: 'status-badge-warning',
      dotVariant: 'warning',
      stateBannerVariant: 'warning',
      stateBannerText: 'Channel is configured but not running. Policy changes apply when it starts.',
      dmPolicyHint: 'DM allowlist changes apply when the channel starts.',
      connected: false,
    ),
    ChannelStatus.pairingNeeded => (
      label: 'Pairing needed',
      badgeClass: 'status-badge-warning',
      dotVariant: 'attention',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
    ChannelStatus.connectionError => (
      label: 'Connection error',
      badgeClass: 'status-badge-error',
      dotVariant: 'error',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
    ChannelStatus.connected => (
      label: 'Connected',
      badgeClass: 'status-badge-success',
      dotVariant: 'live',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: 'DM allowlist changes take effect immediately.',
      connected: true,
    ),
    ChannelStatus.reconnecting => (
      label: 'Reconnecting',
      badgeClass: 'status-badge-warning',
      dotVariant: 'warning',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
  };

  /// The `status-badge-*` suffix, for consumers that compose the class from a
  /// variant token. This is the badge naming itself — never a source for the
  /// dot, banner, hint or action, which are independent [presentation] fields.
  String get badgeVariant => presentation.badgeClass.substring('status-badge-'.length);
}
