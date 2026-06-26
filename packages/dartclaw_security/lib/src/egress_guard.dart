import 'guard.dart';
import 'guard_verdict.dart';

/// Default-deny allowlist for outbound MCP server/tool dispatch.
final class EgressGuard extends Guard {
  /// Allowed outbound MCP tools keyed by external server name.
  final Map<String, Set<String>> allowlist;

  /// Creates an egress guard from server names mapped to allowed tool names.
  EgressGuard({required Map<String, Iterable<String>> allowlist})
    : allowlist = Map.unmodifiable({for (final entry in allowlist.entries) entry.key: Set.unmodifiable(entry.value)});

  @override
  String get name => 'egress';

  @override
  String get category => 'egress';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'outboundMcpToolsCall') return GuardVerdict.pass();
    final input = context.toolInput;
    final server = input?['server'];
    final tool = input?['tool'];
    if (server is! String || server.trim().isEmpty) {
      return GuardVerdict.block('Egress denied: missing server');
    }
    if (tool is! String || tool.trim().isEmpty) {
      return GuardVerdict.block('Egress denied: missing tool');
    }
    final allowedTools = allowlist[server];
    if (allowedTools == null) {
      return GuardVerdict.block('Egress denied: server "$server" is not allowlisted');
    }
    if (!allowedTools.contains(tool)) {
      return GuardVerdict.block('Egress denied: tool "$tool" is not allowlisted for server "$server"');
    }
    return GuardVerdict.pass();
  }
}
