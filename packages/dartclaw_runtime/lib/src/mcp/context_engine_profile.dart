import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show dartclawMcpServerName;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import 'mcp_server.dart';

final _log = Logger('ContextEngineProfile');

const _profileGuardName = 'ContextEngineProfile';

/// The tools a configured MCP client may call.
///
/// An allowlist rather than "everything read-classified": the web-search tools
/// are read-classified and reach third parties on the owner's credentials, so a
/// read classification is not by itself a reason to expose a tool to a client.
/// (`web_fetch` is write-classified and would be excluded either way.)
const contextEngineProfileTools = <String>{
  'context_research',
  'memory_search',
  'memory_read',
  'kg_query',
  'kg_timeline',
};

/// The audit principal for MCP client [clientName].
///
/// Namespaced so it can never collide with the steward principal or a session
/// id: the audit seam writes this straight into `AuditEntry.principal` and into the
/// `sourceEvent` a contextual tool receives.
String mcpClientPrincipal(String clientName) => 'mcp-client:$clientName';

/// Deny-by-default policy admitting one MCP client to the context-engine
/// profile.
///
/// Refusals are audited here because the dispatch seam never sees them: it
/// authorizes through this policy first, and a denied name answers exactly as an
/// unregistered one, so this entry is the only record that the client asked.
final class ContextEngineCallerPolicy implements McpCallerPolicy {
  /// Creates the policy for the client audited as [principal].
  new({required this.principal, GuardAuditLogger? auditLogger}) : _auditLogger = auditLogger;

  /// Audit principal of the client this policy authorizes.
  final String principal;

  final GuardAuditLogger? _auditLogger;

  @override
  bool allows(String toolName) => contextEngineProfileTools.contains(toolName);

  /// Longest tool name recorded in a refusal entry.
  ///
  /// The name is whatever the client put in `params.name`, and a refusal is the
  /// one entry an unregistered name can produce — so without a bound an
  /// authenticated client writes as much attacker-chosen text into the
  /// operator's audit partition as the body cap allows, per request, with no
  /// throttle on authenticated calls. A registered tool name is far shorter
  /// than this, so nothing an operator wants to read is lost.
  static const _maxRecordedToolName = 128;

  @override
  void onDenied(String toolName) {
    final sink = _auditLogger;
    if (sink == null) return;
    final recorded = toolName.length <= _maxRecordedToolName
        ? toolName
        : '${toolName.substring(0, _maxRecordedToolName)}…(${toolName.length} chars)';
    // Fire-and-forget onto the logger's own write chain, which `flush()` drains:
    // the interface returns void, and the call is already refused, so a failed
    // append can lose the record but can never widen access.
    unawaited(
      sink
          .writeEntry(
            AuditEntry(
              timestamp: DateTime.now(),
              guard: _profileGuardName,
              hook: 'mcp_tool_call',
              verdict: 'block',
              reason: 'outside the context-engine profile',
              rawProviderToolName: recorded,
              server: dartclawMcpServerName,
              tool: recorded,
              decision: 'deny',
              principal: principal,
            ),
          )
          .catchError((Object error) => _log.severe('Failed to audit refused MCP client call: $error')),
    );
  }
}
