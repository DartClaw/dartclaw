/// Verifies Google-issued JWTs against Google's published certificate sets.
abstract interface class GoogleJwtVerifier {
  /// Verifies the Bearer token in [authHeader].
  ///
  /// Returns `true` when the token is valid, `false` otherwise.
  Future<bool> verify(String? authHeader);

  /// Clears the cached certificate set, forcing a fresh fetch on the next
  /// [verify] call.
  void invalidateCache();
}
