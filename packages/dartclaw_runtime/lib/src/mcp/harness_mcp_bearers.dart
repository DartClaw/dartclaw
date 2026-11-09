import 'package:dartclaw_kernel/dartclaw_kernel.dart' show constantTimeEquals;

import '../auth/token_service.dart';
import 'mcp_server.dart' show McpCaller;

/// Host-minted MCP bearers, one per host harness.
///
/// The gateway token is shared by every host harness, so on its own it cannot say which harness a call came from.
/// A bearer minted here is valid only while its harness lives and resolves to that harness's [McpCaller], so a tool
/// runs as the caller and turn actually in flight there.
final class HarnessMcpBearers {
  final Map<String, McpCaller> _callers = {};

  /// Mints a bearer that resolves to [caller] until [revoke]d.
  String mint(McpCaller caller) {
    final bearer = TokenService.generate();
    _callers[bearer] = caller;
    return bearer;
  }

  /// Invalidates [bearer]. Idempotent.
  void revoke(String bearer) => _callers.remove(bearer);

  /// The caller [bearer] was minted for, or null when it is not a live harness bearer.
  ///
  /// Compares against every live bearer without short-circuiting, so the work done does not reveal which one a guess
  /// was closest to.
  McpCaller? resolve(String bearer) {
    McpCaller? resolved;
    for (final entry in _callers.entries) {
      if (constantTimeEquals(bearer, entry.key)) resolved ??= entry.value;
    }
    return resolved;
  }
}
