import 'package:dartclaw_core/dartclaw_core.dart' show TurnProvenance;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show constantTimeEquals;

import '../auth/token_service.dart';
import 'mcp_server.dart' show McpCallerIdentity;

/// What a host harness's bearer stands for: the turn it is running, whom that turn serves, and, for a logical agent,
/// the tools it may see.
typedef HarnessMcpCaller = ({
  TurnProvenance? Function() activeTurn,
  McpCallerIdentity? Function()? identity,
  bool Function(String toolName)? listsTool,
});

/// Host-minted MCP bearers, one per host harness.
///
/// The gateway token is shared by every host harness, so on its own it cannot say which harness a call came from.
/// A bearer minted here is valid only while its harness lives and resolves to that harness's active turn and caller,
/// so a tool that reads either attributes a call to the turn actually running there.
final class HarnessMcpBearers {
  final Map<String, HarnessMcpCaller> _callers = {};

  /// Mints a bearer that resolves to [activeTurn] until [revoke]d.
  ///
  /// [identity] resolves whom the harness is serving, or null while it runs no turn; without it the bearer carries no
  /// caller identity. [listsTool] narrows what `tools/list` shows this harness; null lists every tool.
  String mint(
    TurnProvenance? Function() activeTurn, {
    McpCallerIdentity? Function()? identity,
    bool Function(String toolName)? listsTool,
  }) {
    final bearer = TokenService.generate();
    _callers[bearer] = (activeTurn: activeTurn, identity: identity, listsTool: listsTool);
    return bearer;
  }

  /// Invalidates [bearer]. Idempotent.
  void revoke(String bearer) => _callers.remove(bearer);

  /// The caller [bearer] was minted for, or null when it is not a live harness bearer.
  ///
  /// Compares against every live bearer without short-circuiting, so the work done does not reveal which one a guess
  /// was closest to.
  HarnessMcpCaller? resolve(String bearer) {
    HarnessMcpCaller? resolved;
    for (final entry in _callers.entries) {
      if (constantTimeEquals(bearer, entry.key)) resolved ??= entry.value;
    }
    return resolved;
  }
}
