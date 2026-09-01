import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock, SubscriptionCredentialStore;

/// Drives the vendor Codex CLI's own refresh against the dedicated [codexHome].
///
/// Never constructs a token request: the vendor owns the client id, endpoint,
/// one-time-use rotation and persistence. A throw means the drive did not
/// complete, not that the credential is spent.
typedef CodexVendorRefresh = Future<void> Function(String codexHome);

/// A ChatGPT-subscription credential presented for one Codex request or spawn.
final class CodexSubscriptionCredential {
  const new({required this.accessToken, this.accountId, required this.expiresAt});

  final String accessToken;
  final DateTime expiresAt;

  /// The account the token belongs to; the backend accepts a single-account
  /// request without it.
  final String? accountId;
}

/// What one pass of the freshness gate produced for a dedicated Codex store.
/// Distinct types rather than one carrier with a status field: a caller must
/// not be able to treat a spent refresh token as a retryable failure, or a
/// concurrent rotation as either.
sealed class CodexRefreshOutcome {
  const new();
}

/// The store holds a usable credential — already fresh, or rotated by this pass.
final class CodexCredentialPresented extends CodexRefreshOutcome {
  const new(this.credential);

  final CodexSubscriptionCredential credential;
}

/// Another writer rotated the store mid-pass, so the turn continues on that
/// writer's usable credential with no operator action: one-time-use rotation
/// makes losing the race the expected outcome of concurrent demand, not a fault.
final class CodexCredentialRotatedAway extends CodexRefreshOutcome {
  const new(this.credential);

  final CodexSubscriptionCredential credential;
}

/// The refresh token itself is spent, so only an interactive login recovers.
/// Both fields are credential-free operator text: what happened, and the way out.
final class CodexReauthRequired extends CodexRefreshOutcome {
  const new({required this.detail, required this.remediation});

  final String detail;
  final String remediation;
}

/// The refresh did not complete for a reason that may pass on its own. Carries
/// no re-authentication semantics: a turn fails or retries, and the retry
/// re-enters the gate against whatever the store holds by then. [detail] is
/// credential-free operator text.
final class CodexRefreshFailed extends CodexRefreshOutcome {
  const new(this.detail);

  final String detail;
}

/// The only thing in DartClaw that rotates one dedicated Codex store.
///
/// Every DartClaw-initiated use — a mediated container request and a host-mode
/// spawn alike — passes [present] first, so a turn starts on the freshest token
/// the store can produce and never on an expired one. Concurrent demand
/// collapses onto one refresh: the in-flight future is published before the
/// first `await`, so a
/// second caller reaching the gate in the same event-loop turn joins it instead
/// of making a second token call. The guarantee covers DartClaw's own refreshes
/// only — the vendor CLI stays a routine second refresher for a turn outliving
/// its token, and [CodexCredentialRotatedAway] is the designed recovery.
final class CodexRefreshAuthority {
  new({
    required SubscriptionCredentialStore store,
    required CodexVendorRefresh vendorRefresh,
    Duration nearExpiry = nearExpiryWindow,
    RepoLock? lock,
    DateTime Function()? now,
  }) : _store = store,
       _vendorRefresh = vendorRefresh,
       _nearExpiry = nearExpiry,
       _lock = lock ?? RepoLock(),
       _now = now ?? DateTime.now;

  /// Remaining access-token life at or below which the gate refreshes first.
  /// Deliberately strictly inside the vendor's own 5-minute proactive window:
  /// the conditional refresh DartClaw drives acts only within that window, so
  /// asking at its exact edge risks a decline for being a tick early. This is
  /// the trigger for demanding a rotation, never the test for whether a token
  /// is usable — that one is expiry itself.
  static const nearExpiryWindow = Duration(minutes: 4);

  /// How long the vendor leaves a refresh token usable without rotating it. Past
  /// this, a refresh that produced nothing is spent rather than merely
  /// unreachable — the only signal separating the two.
  static const refreshTokenStaleness = Duration(days: 8);

  final SubscriptionCredentialStore _store;
  final CodexVendorRefresh _vendorRefresh;
  final Duration _nearExpiry;
  final RepoLock _lock;
  final DateTime Function() _now;

  Future<CodexRefreshOutcome>? _inFlight;

  /// The dedicated `CODEX_HOME` this authority rotates.
  String get codexHome => _store.codexHome;

  /// The credential to use now, refreshing first when it is near or at expiry.
  /// Reads the store on every call: the access token rotates one-time-use and
  /// has been observed rotating mid-session, so a value cached at startup, at
  /// construction, or once per turn is already the wrong one.
  Future<CodexRefreshOutcome> present() => _usable() ?? _refresh();

  /// Runs [prepare] against a gated store held against a concurrent refresh, so
  /// the vendor CLI is never pointed at one mid-rotation. The lock covers
  /// preparation only — once the CLI runs it owns the store as a second writer,
  /// which is what [CodexCredentialRotatedAway] exists for. Gates through
  /// [_gateLocked] rather than [present] on purpose: the in-flight memo may hold
  /// a refresh still *queued* on this same lock, and a holder awaiting it would
  /// wait on something queued behind itself.
  Future<T> prepareHostSpawn<T>(FutureOr<T> Function(CodexRefreshOutcome) prepare) =>
      _lock.acquire(codexHome, () async => prepare(await _gateLocked()));

  /// The store's credential when it is usable without refreshing, else `null`.
  Future<CodexRefreshOutcome>? _usable() {
    final current = _store.readCodexAuth();
    if (current == null || _isNearExpiry(current.expiresAt)) return null;
    return Future.value(CodexCredentialPresented(_credentialOf(current)));
  }

  /// The gate inside the critical section, where the store is exclusively ours.
  /// Re-reads first: a refresh that completed while this caller queued already
  /// produced a usable token, and rotating again would spend one for nothing.
  Future<CodexRefreshOutcome> _gateLocked() => _usable() ?? _runRefresh();

  /// Publishing the in-flight future before any `await` is the whole contract: a
  /// second caller in this event-loop turn must see it, not merely discover
  /// afterwards that a refresh had happened.
  Future<CodexRefreshOutcome> _refresh() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final started = _lock.acquire(codexHome, _gateLocked);
    _inFlight = started;
    unawaited(started.whenComplete(() => _clearInFlight(started)));
    return started;
  }

  void _clearInFlight(Future<CodexRefreshOutcome> settled) {
    if (identical(_inFlight, settled)) _inFlight = null;
  }

  /// Never throws: a drive that failed is an outcome the caller classifies, and
  /// an escaping error would also poison every caller joined to the same future.
  Future<CodexRefreshOutcome> _runRefresh() async {
    Object? driveError;
    try {
      await _vendorRefresh(codexHome);
    } on Object catch (error) {
      driveError = error;
    }

    final rotated = _store.readCodexAuth();
    if (rotated != null && !_isNearExpiry(rotated.expiresAt)) {
      final credential = _credentialOf(rotated);
      // The store was inside the window when this pass started and is outside
      // it now while this pass's own drive failed, so a second writer produced
      // it.
      return driveError == null ? CodexCredentialPresented(credential) : CodexCredentialRotatedAway(credential);
    }

    // Nothing rotated, and only a spent refresh token is terminal — including
    // over a token with minutes left, which nothing can renew once the lineage
    // is gone. A store the drive left unreadable is terminal on the same
    // grounds, unless the drive *threw*: an interrupted vendor process explains
    // that read as well as a spent token does, and the next pass re-reads
    // whatever it left behind.
    final unrecoverable = rotated == null ? driveError == null : _isRefreshTokenSpent(rotated.lastRefresh);
    if (unrecoverable) {
      return const CodexReauthRequired(
        detail: 'the stored Codex subscription credential can no longer be refreshed',
        remediation:
            'Run "dartclaw auth codex" to perform a new "codex login" against the DartClaw-dedicated CODEX_HOME.',
      );
    }

    // The rotation the gate asked for did not happen, but the token the store
    // holds is still one the backend accepts and one a later pass can still
    // renew. The window says when to *ask* for a rotation; refusing the answer
    // would fail the turn on a usable credential.
    if (rotated != null && _hasLifeLeft(rotated.expiresAt)) return CodexCredentialPresented(_credentialOf(rotated));

    return CodexRefreshFailed(
      driveError == null
          ? 'refreshing the stored Codex subscription credential produced no usable token'
          : 'the Codex credential refresh could not be completed',
    );
  }

  /// A store that never recorded a refresh cannot be dated, so it reads as
  /// unreachable rather than spent — refusing a recoverable store is worse.
  bool _isRefreshTokenSpent(DateTime? lastRefresh) =>
      lastRefresh != null && _now().toUtc().difference(lastRefresh) > refreshTokenStaleness;

  bool _isNearExpiry(DateTime expiresAt) => expiresAt.difference(_now().toUtc()) <= _nearExpiry;

  bool _hasLifeLeft(DateTime expiresAt) => expiresAt.isAfter(_now().toUtc());

  static CodexSubscriptionCredential _credentialOf(
    ({String accessToken, String? accountId, DateTime expiresAt, DateTime? lastRefresh}) auth,
  ) => CodexSubscriptionCredential(accessToken: auth.accessToken, accountId: auth.accountId, expiresAt: auth.expiresAt);
}
