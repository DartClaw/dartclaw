part of 'dartclaw_event.dart';

/// Operator-facing credential health for one provider.
///
/// [jsonName] is the frozen wire string emitted at the server API boundary and
/// rendered on the settings page.
enum CredentialHealthState {
  /// The presented credential is usable and nothing ages out soon.
  healthy('healthy'),

  /// Still usable, but inside the provider's renewal warning window.
  nearingExpiry('nearing-expiry'),

  /// A refresh attempt failed transiently; the credential is not yet unusable.
  refreshFailure('refresh-failure'),

  /// No usable credential can be presented — the operator must re-authenticate.
  reauthRequired('reauth-required'),

  /// Upstream rejected the mediated credential form itself, so re-authenticating
  /// cannot help.
  contractBreak('contract-break'),

  /// Health is uncheckable — no expiry could be computed — rather than degraded.
  unknown('unknown');

  /// Frozen wire string for this state.
  final String jsonName;

  new(this.jsonName);

  /// Whether this state needs operator attention.
  ///
  /// [unknown] is not degraded: an uncheckable credential is reported as such
  /// rather than warned about.
  bool get isDegraded => this != healthy && this != unknown;
}

/// Fired when a provider's credential health transitions to a new state.
///
/// Emitted by the single credential-health writer on a *transition* only —
/// never once per probe — so the scheduled probe, the fail-closed admission
/// refusal, and the upstream adapter classifications report one state per
/// provider. Carries no credential material.
final class CredentialHealthChangedEvent extends DartclawEvent {
  /// Provider whose credential health changed.
  final String providerId;

  /// The state the provider transitioned into.
  final CredentialHealthState state;

  /// Human-readable explanation of the state; never credential material.
  final String detail;

  /// Command that resolves the condition, or `null` when no operator action
  /// would help (a broken mediation contract, a transient refresh failure).
  final String? remediation;

  /// The presented credential's resolved lifetime when one is known, carrying
  /// the derived-vs-exact flag.
  final CredentialExpiry? expiry;

  @override
  /// Timestamp of the transition.
  final DateTime timestamp;

  /// Creates a credential-health transition event.
  new({
    required this.providerId,
    required this.state,
    required this.detail,
    required this.timestamp,
    this.remediation,
    this.expiry,
  });

  @override
  String toString() => 'CredentialHealthChangedEvent(provider: $providerId, state: ${state.jsonName})';
}
