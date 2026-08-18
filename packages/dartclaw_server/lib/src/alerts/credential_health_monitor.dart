import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show CredentialHealthChangedEvent, CredentialHealthState, EventBus;
import 'package:logging/logging.dart';

import '../provider_status_service.dart';

/// What one provider would present upstream, with the family that decides its
/// renewal deadline.
///
/// [family] is the *resolved* family (a provider alias resolves to the vendor
/// whose credential it presents), so a window is never picked from a bare
/// provider id.
typedef ProviderCredential = ({String family, CredentialResolution resolution});

/// Resolves, per configured provider, the credential it would present now.
///
/// Invoked once per probe so a credential renewed between runs is seen; the
/// monitor itself never opens a credential store. Providers that need no
/// credential at all are omitted rather than reported as unauthenticated.
typedef CredentialResolutionSource = Map<String, ProviderCredential> Function();

/// Single writer of per-provider credential health.
///
/// The scheduled probe, the fail-closed admission refusal, and the upstream
/// adapter classifications all enter here: the monitor holds the last-known
/// state per provider, acts only on a *transition*, and fans that transition
/// out to the [EventBus] (which `AlertRouter` already consumes), to
/// [ProviderStatusService], and to a warning log line. Producers must call
/// [report] rather than firing [CredentialHealthChangedEvent] themselves — a
/// second producer would reintroduce the divergent per-path reports this type
/// exists to prevent.
///
/// The warning line is written unconditionally rather than only when no alert
/// target is configured: `AlertRouter` returns early when alerts are disabled,
/// when no target is configured, or when routing excludes the type, and
/// credential health must never be silent.
///
/// Last-known state is process-local, so a restart re-announces a condition
/// that is still true — deliberate, since the operator has no record that the
/// pre-restart alert was ever delivered.
class CredentialHealthMonitor {
  /// Lead time on the Claude `setup-token`'s derived ~1-year expiry.
  static const claudeWarningWindow = Duration(days: 30);

  /// How long a Codex sign-in survives without a refresh, measured from the
  /// dedicated store's last write. The access token's JWT `exp` is minutes-scale
  /// and refreshed without operator action, so it is never a health signal.
  static const codexStalenessLifetime = Duration(days: 8);

  /// Lead time on [codexStalenessLifetime].
  static const codexWarningWindow = Duration(hours: 48);

  static final _log = Logger('CredentialHealthMonitor');

  final EventBus _eventBus;
  final ProviderStatusService _providerStatus;
  final CredentialResolutionSource _resolveCredentials;
  final String? _credentialsDir;
  final DateTime Function() _now;

  final Map<String, _KnownHealth> _lastKnown = <String, _KnownHealth>{};

  /// Creates the monitor over the live [providerStatus] the API reads.
  ///
  /// [credentialsDir] is the dedicated subscription store this deployment
  /// resolves. It is threaded into every remediation this monitor emits, so an
  /// operator told to run `dartclaw auth` learns which store it has to reach —
  /// `data_dir` selects it, and a `serve --data-dir` reads one no default
  /// invocation addresses.
  new({
    required EventBus eventBus,
    required ProviderStatusService providerStatus,
    required CredentialResolutionSource resolveCredentials,
    String? credentialsDir,
    DateTime Function()? now,
  }) : _eventBus = eventBus,
       _providerStatus = providerStatus,
       _resolveCredentials = resolveCredentials,
       _credentialsDir = credentialsDir,
       // UTC: the recorded timestamps cross the API boundary next to
       // store-supplied UTC expiries, and a local one serializes with no offset.
       _now = now ?? (() => DateTime.now().toUtc());

  /// Classifies every configured provider's credential and applies the verdict.
  ///
  /// Returns a one-line summary for the scheduled job's result.
  String probe() {
    final now = _now();
    final credentials = _resolveCredentials();
    var degraded = 0;
    credentials.forEach((providerId, credential) {
      final verdict = _classify(providerId, credential.family, credential.resolution, now);
      if (verdict.state.isDegraded) degraded++;
      _apply(
        providerId: providerId,
        family: credential.family,
        state: verdict.state,
        detail: verdict.detail,
        remediation: verdict.remediation,
        mode: credential.resolution.mode,
        expiry: verdict.expiry,
        now: now,
      );
    });
    final checked = credentials.length;
    return 'checked $checked provider${checked == 1 ? '' : 's'}, $degraded degraded';
  }

  /// Records a verdict a detecting path other than the probe reached.
  ///
  /// This is the seam the fail-closed admission refusal and the upstream
  /// refresh/response classifications report through, so a condition detected
  /// between probe runs updates the provider cards as well as alerting, and the
  /// probe that later finds the same condition raises no second alert. A usage
  /// limit is not a credential-health condition and has no entry here.
  ///
  /// [detail] reaches operator-facing sinks verbatim — the alert body, the
  /// chat card and the warning log line — so callers must not build it from
  /// credential material or from an unscrubbed upstream response body.
  ///
  /// [remediation] defaults to the provider family's re-authentication command
  /// for the states that command resolves. A contract break and a transient
  /// refresh failure carry none even when one is passed: re-authenticating
  /// fixes neither, and this seam owns that wording contract.
  void report({
    required String providerId,
    required CredentialHealthState state,
    required String detail,
    String? remediation,
  }) {
    final known = _lastKnown[ProviderIdentity.normalize(providerId)];
    final family = known?.family ?? ProviderIdentity.family(providerId);
    _apply(
      providerId: providerId,
      family: family,
      state: state,
      detail: detail,
      remediation: _reauthResolves(state) ? remediation ?? _renewal(family) : null,
      mode: known?.mode,
      expiry: known?.expiry,
      now: _now(),
    );
  }

  void _apply({
    required String providerId,
    required String family,
    required CredentialHealthState state,
    required String detail,
    required String? remediation,
    required CredentialMode? mode,
    required CredentialExpiry? expiry,
    required DateTime now,
  }) {
    final key = ProviderIdentity.normalize(providerId);
    // An unseen provider is assumed healthy, so a first probe announces a
    // degradation but not the ordinary healthy baseline.
    final previous = _lastKnown[key]?.state ?? CredentialHealthState.healthy;
    _lastKnown[key] = _KnownHealth(state: state, family: family, mode: mode, expiry: expiry);
    _providerStatus.recordCredentialHealth(
      providerId: providerId,
      state: state,
      checkedAt: now,
      mode: mode,
      expiry: expiry,
      remediation: remediation,
    );
    if (previous == state) return;

    _eventBus.fire(
      CredentialHealthChangedEvent(
        providerId: providerId,
        state: state,
        detail: detail,
        remediation: remediation,
        expiry: expiry,
        timestamp: now,
      ),
    );
    if (state.isDegraded) {
      _log.warning(
        "Provider '$providerId' credential health: ${state.jsonName}. $detail"
        '${remediation == null ? '' : ' Remediation: $remediation'}',
      );
    }
  }

  ({CredentialHealthState state, String detail, String? remediation, CredentialExpiry? expiry}) _classify(
    String providerId,
    String family,
    CredentialResolution resolution,
    DateTime now,
  ) {
    if (!resolution.isPresent) {
      final reason = resolution.reason!;
      // The vendor binary carries its own interactive login: the provider is
      // authenticated, but by a credential DartClaw neither holds nor inspects,
      // so its lifetime is uncheckable rather than absent. Reporting it as
      // reauth-required would page the operator about a provider that works.
      // Admission is unaffected — an interactive login is still unusable inside
      // a container, and the fail-closed gate refuses there on its own terms.
      final remediation = credentialRemediationFor(
        reason,
        providerId: providerId,
        family: family,
        credentialsDir: _credentialsDir,
      );
      if (_vendorLoginStandsIn(reason) &&
          _vendorLoginIsVerifiable(family) &&
          _providerStatus.binaryAuthenticated(providerId)) {
        return (
          state: CredentialHealthState.unknown,
          detail:
              'Authenticated via an interactive vendor login DartClaw does not manage, so its lifetime is '
              'uncheckable. Store a DartClaw-managed credential to make it checkable.',
          remediation: remediation,
          expiry: null,
        );
      }
      return (
        state: CredentialHealthState.reauthRequired,
        // Which credential is missing and why is stated once, by the
        // remediation: every sink renders detail and remediation together, so
        // repeating the reason here would print the same sentence twice.
        detail: 'No credential can be presented.',
        remediation: remediation,
        expiry: null,
      );
    }
    if (resolution.mode == CredentialMode.apiKey) {
      return (
        state: CredentialHealthState.healthy,
        detail: 'Authenticated with an API key, which does not age out.',
        remediation: null,
        expiry: null,
      );
    }

    final deadline = _renewalDeadline(family, resolution.expiry);
    final window = _warningWindow(family);
    if (deadline == null || window == null) {
      return (
        state: CredentialHealthState.unknown,
        detail: 'Subscription credential has no computable renewal deadline.',
        remediation: null,
        expiry: null,
      );
    }

    final remaining = deadline.expiresAt.difference(now);
    if (remaining > window) {
      return (
        state: CredentialHealthState.healthy,
        detail: _deadlineDetail(family, remaining),
        remediation: null,
        expiry: deadline,
      );
    }
    final state = remaining > Duration.zero
        ? CredentialHealthState.nearingExpiry
        : CredentialHealthState.reauthRequired;
    return (state: state, detail: _deadlineDetail(family, remaining), remediation: _renewal(family), expiry: deadline);
  }

  /// The renewal deadline, reported in place of the credential's own expiry.
  ///
  /// The Claude `setup-token` is static, so its derived expiry *is* the
  /// deadline. The operator-actionable Codex deadline is refresh-token
  /// staleness measured from the store's last write — never the access token's
  /// minutes-scale `exp`, which refresh replaces without operator action and
  /// which would otherwise render as a credential expiring in minutes.
  ///
  /// Neither deadline is read verbatim from the credential, so both are flagged
  /// derived.
  static CredentialExpiry? _renewalDeadline(String family, CredentialExpiry? expiry) {
    if (expiry == null) return null;
    final deadline = switch (family) {
      ProviderIdentity.claude => expiry.expiresAt,
      ProviderIdentity.codex => expiry.issuedAt.add(codexStalenessLifetime),
      _ => null,
    };
    if (deadline == null) return null;
    return CredentialExpiry(issuedAt: expiry.issuedAt, expiresAt: deadline, derived: true);
  }

  static Duration? _warningWindow(String family) => switch (family) {
    ProviderIdentity.claude => claudeWarningWindow,
    ProviderIdentity.codex => codexWarningWindow,
    _ => null,
  };

  static String _deadlineDetail(String family, Duration remaining) {
    final subject = switch (family) {
      ProviderIdentity.claude => 'Claude setup-token',
      ProviderIdentity.codex => 'Codex sign-in',
      _ => 'Subscription credential',
    };
    return remaining > Duration.zero
        ? '$subject needs renewal within ${_remainingLabel(remaining)}.'
        : '$subject is no longer usable: its renewal deadline passed ${_remainingLabel(-remaining)} ago.';
  }

  static String _remainingLabel(Duration span) {
    final days = span.inDays;
    if (days > 0) return '$days day${days == 1 ? '' : 's'}';
    final hours = span.inHours;
    if (hours > 0) return '$hours hour${hours == 1 ? '' : 's'}';
    return 'less than an hour';
  }

  /// Whether an interactive vendor login can stand in for the credential that
  /// is missing.
  ///
  /// Only where the operator expressed no incompatible preference: a forced
  /// `api_key` selection with no key, or an unrecognized `auth` value, is a
  /// misconfiguration the operator must fix — an ambient login neither
  /// satisfies the selection nor makes the provider healthy, so those keep
  /// alerting.
  static bool _vendorLoginStandsIn(CredentialUnavailableReason reason) =>
      reason == CredentialUnavailableReason.subscriptionAbsent || reason == CredentialUnavailableReason.noneConfigured;

  /// Whether a positive auth probe for this family is evidence the login is
  /// still *live* — Claude only.
  ///
  /// `ProviderValidator.probeAuthStatus` branches by family. Claude runs
  /// `claude auth status` and requires `loggedIn: true`. Codex instead only
  /// checks that `~/.codex/auth.json` parses with a non-empty access token —
  /// no expiry, no revocation — so a sign-in that died months ago still reads
  /// authenticated, and exempting it would trade a false alarm for a missed
  /// one. An unrecognized family also takes the `auth status` arm, but nothing
  /// says an arbitrary binary means by it what Claude does, so it is not
  /// exempt either.
  static bool _vendorLoginIsVerifiable(String family) => family == ProviderIdentity.claude;

  /// The renewal instruction for a credential that exists but has aged out or
  /// was found dead upstream, naming the store it has to land in.
  ///
  /// Authored by `dartclaw_config` rather than here: a remediation this monitor
  /// wrote itself could name a different store than the refusal an operator
  /// meets at admission or at startup, which is the drift the single-author rule
  /// exists to prevent.
  String? _renewal(String family) => credentialRenewalFor(family, credentialsDir: _credentialsDir);

  /// Whether re-authenticating is what resolves [state]; a broken mediation
  /// contract and a transient refresh failure are not fixed by logging in.
  static bool _reauthResolves(CredentialHealthState state) =>
      state == CredentialHealthState.nearingExpiry || state == CredentialHealthState.reauthRequired;
}

class _KnownHealth {
  final CredentialHealthState state;
  final String family;
  final CredentialMode? mode;
  final CredentialExpiry? expiry;

  const new({required this.state, required this.family, this.mode, this.expiry});
}
