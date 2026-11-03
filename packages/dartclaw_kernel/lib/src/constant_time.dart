import 'dart:convert';

/// Constant-time string comparison to prevent timing attacks on secrets.
///
/// Returns true only if [a] and [b] are equal, but takes the same amount
/// of time regardless of where (or whether) they differ — preventing
/// attackers from inferring correct characters via response-time analysis.
///
/// An empty [a] or [b] never matches. Every caller compares a secret, and an
/// unresolvable credential reference — an undefined `${VAR}` that
/// `envSubstitute` resolves to `''` — must not degrade into a credential that
/// an equally empty candidate satisfies.
bool constantTimeEquals(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  final aBytes = utf8.encode(a);
  final bBytes = utf8.encode(b);
  final maxLength = aBytes.length > bBytes.length ? aBytes.length : bBytes.length;
  final paddedA = List<int>.filled(maxLength, 0)..setRange(0, aBytes.length, aBytes);
  final paddedB = List<int>.filled(maxLength, 0)..setRange(0, bBytes.length, bBytes);

  var result = aBytes.length ^ bBytes.length;
  for (var i = 0; i < maxLength; i++) {
    result |= paddedA[i] ^ paddedB[i];
  }
  return result == 0;
}
