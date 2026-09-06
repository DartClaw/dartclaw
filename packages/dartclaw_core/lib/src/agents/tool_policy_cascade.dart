import 'package:logging/logging.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// 3-layer tool policy evaluator.
///
/// Evaluation order (most restrictive wins):
/// 1. Global deny — always blocked regardless of agent
/// 2. Agent deny — blocked for this specific agent
/// 3. Sandbox allow — only explicitly listed tools are permitted (closed set)
///
/// A capability passes only if it is NOT in global deny, NOT in agent deny,
/// AND IS in the agent's allow set. The main agent has no agent identity, so
/// only the global deny binds it. Claude's exact schema-discovery helper may
/// pass after deny evaluation; the selected capability is evaluated separately.
class ToolPolicyCascade {
  final Set<String> globalDeny;
  final Map<String, Set<String>> agentDeny;
  final Map<String, Set<String>> agentAllow;

  new({
    Set<String> globalDeny = const {},
    Map<String, Set<String>> agentDeny = const {},
    Map<String, Set<String>> agentAllow = const {},
  }) : globalDeny = _normalizeEntries(globalDeny),
       agentDeny = _normalizePolicyMap(agentDeny),
       agentAllow = _normalizePolicyMap(agentAllow);

  /// Normalizes a known provider-native policy entry to its stable name.
  static String normalizeEntry(String entry) => _knownToolNames[entry] ?? entry;

  /// Returns true if the tool is allowed for [agentId], or for the main agent
  /// when [agentId] is null.
  bool isAllowed(String? agentId, String canonicalToolName, {String? rawProviderToolName}) {
    final names = {canonicalToolName, ?rawProviderToolName};
    final denyNames = {...names, if (rawProviderToolName?.startsWith('mcp_') ?? false) 'mcp_call'};

    // Layer 1: global deny
    if (globalDeny.any(denyNames.contains)) return false;
    if (agentId == null) return true;

    // Layer 2: agent-specific deny
    final agentDenySet = agentDeny[agentId];
    if (agentDenySet != null && agentDenySet.any(denyNames.contains)) return false;

    // Layer 3: sandbox allow (closed set — must be explicitly listed)
    final agentAllowSet = agentAllow[agentId];
    if (agentAllowSet == null || agentAllowSet.isEmpty) return true; // no sandbox = allow all
    // Discovery exposes schemas only; the selected tool is evaluated separately.
    if (canonicalToolName == 'claude:ToolSearch' && rawProviderToolName == 'ToolSearch') return true;
    return agentAllowSet.any(names.contains);
  }

  static const _knownToolNames = <String, String>{
    'WebSearch': 'web_search',
    'WebFetch': 'web_fetch',
    'Bash': 'shell',
    'command_execution': 'shell',
    'Read': 'file_read',
    'Write': 'file_write',
    'write_file': 'file_write',
    'Edit': 'file_edit',
    'NotebookEdit': 'file_edit',
    'edit_file': 'file_edit',
  };

  static Set<String> _normalizeEntries(Set<String> entries) => Set.unmodifiable({
    for (final entry in entries) ...{entry, normalizeEntry(entry)},
  });

  static Map<String, Set<String>> _normalizePolicyMap(Map<String, Set<String>> policies) =>
      Map.unmodifiable({for (final entry in policies.entries) entry.key: _normalizeEntries(entry.value)});
}

/// Guard that wraps [ToolPolicyCascade] for integration with [GuardChain].
///
/// Uses `context.agentId` for agent-scoped policy evaluation. Without one (the
/// main agent) only the global deny applies.
class ToolPolicyGuard extends Guard {
  static final _log = Logger('ToolPolicyGuard');

  final ToolPolicyCascade cascade;

  new({required this.cascade});

  @override
  String get name => 'ToolPolicyGuard';

  @override
  String get category => 'policy';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall') return GuardVerdict.pass();

    final agentId = context.agentId;
    final canonicalToolName = context.toolName;
    if (canonicalToolName == null) return GuardVerdict.pass();
    final displayName = context.rawProviderToolName ?? canonicalToolName;

    if (!cascade.isAllowed(agentId, canonicalToolName, rawProviderToolName: context.rawProviderToolName)) {
      final subject = agentId == null ? 'the main agent' : 'agent "$agentId"';
      _log.warning('Tool "$displayName" blocked by policy for $subject');
      return GuardVerdict.block('Tool "$displayName" not allowed for $subject');
    }

    return GuardVerdict.pass();
  }
}
