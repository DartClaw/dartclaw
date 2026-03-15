import 'package:logging/logging.dart';
import 'package:dartclaw_security/dartclaw_security.dart';

/// 3-layer tool policy evaluator.
///
/// Evaluation order (most restrictive wins):
/// 1. Global deny — always blocked regardless of agent
/// 2. Agent deny — blocked for this specific agent
/// 3. Sandbox allow — only explicitly listed tools are permitted (closed set)
///
/// A tool passes only if it is NOT in global deny, NOT in agent deny, AND
/// IS in the agent's allow set.
class ToolPolicyCascade {
  final Set<String> globalDeny;
  final Map<String, Set<String>> agentDeny;
  final Map<String, Set<String>> agentAllow;

  const ToolPolicyCascade({this.globalDeny = const {}, this.agentDeny = const {}, this.agentAllow = const {}});

  /// Returns true if [toolName] is allowed for [agentId].
  bool isAllowed(String agentId, String toolName) {
    // Layer 1: global deny
    if (globalDeny.contains(toolName)) return false;

    // Layer 2: agent-specific deny
    final agentDenySet = agentDeny[agentId];
    if (agentDenySet != null && agentDenySet.contains(toolName)) return false;

    // Layer 3: sandbox allow (closed set — must be explicitly listed)
    final agentAllowSet = agentAllow[agentId];
    if (agentAllowSet == null) return true; // no sandbox = allow all
    return agentAllowSet.contains(toolName);
  }
}

/// Guard that wraps [ToolPolicyCascade] for integration with [GuardChain].
///
/// Uses `context.agentId` for agent-scoped policy evaluation. When no agent
/// context is set (i.e. main agent), passes all tools through.
class ToolPolicyGuard extends Guard {
  static final _log = Logger('ToolPolicyGuard');

  final ToolPolicyCascade cascade;

  ToolPolicyGuard({required this.cascade});

  @override
  String get name => 'ToolPolicyGuard';

  @override
  String get category => 'policy';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall') return GuardVerdict.pass();

    final agentId = context.agentId;
    if (agentId == null) return GuardVerdict.pass();

    final toolName = context.toolName;
    if (toolName == null) return GuardVerdict.pass();

    if (!cascade.isAllowed(agentId, toolName)) {
      _log.warning('Tool "$toolName" blocked by policy for agent "$agentId"');
      return GuardVerdict.block('Tool "$toolName" not allowed for agent "$agentId"');
    }

    return GuardVerdict.pass();
  }
}
