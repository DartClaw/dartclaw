import 'package:dartclaw_core/dartclaw_core.dart' show TurnProvenance;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show constantTimeEquals;

import '../auth/token_service.dart';

/// Host-minted MCP bearers, one per host harness.
///
/// The gateway token is shared by every host harness, so on its own it cannot say which harness a call came from.
/// A bearer minted here is valid only while its harness lives and resolves to that harness's active turn, so a
/// tool that reads the turn attributes a call to the turn actually running there.
final class HarnessMcpBearers {
  final Map<String, TurnProvenance? Function()> _activeTurns = {};

  /// Mints a bearer that resolves to [activeTurn] until [revoke]d.
  String mint(TurnProvenance? Function() activeTurn) {
    final bearer = TokenService.generate();
    _activeTurns[bearer] = activeTurn;
    return bearer;
  }

  /// Invalidates [bearer]. Idempotent.
  void revoke(String bearer) => _activeTurns.remove(bearer);

  /// The active-turn resolver [bearer] was minted for, or null when it is not a live harness bearer.
  ///
  /// Compares against every live bearer without short-circuiting, so the work done does not reveal which one a guess
  /// was closest to.
  TurnProvenance? Function()? resolve(String bearer) {
    TurnProvenance? Function()? resolved;
    for (final entry in _activeTurns.entries) {
      if (constantTimeEquals(bearer, entry.key)) resolved ??= entry.value;
    }
    return resolved;
  }
}
