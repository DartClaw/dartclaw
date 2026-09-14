part of 'claude_code_harness.dart';

extension _ClaudeCodeHarnessControl on ClaudeCodeHarness {
  Future<void> _handleControlRequest(String requestId, String subtype, Map<String, dynamic> data) async {
    switch (subtype) {
      case 'can_use_tool':
        final skipNativePermissions = _nativePermissionsSkipped;
        if (skipNativePermissions) {
          // Defensive dead code: --dangerously-skip-permissions suppresses
          // can_use_tool requests, and guard evaluation runs via PreToolUse hooks.
          ClaudeCodeHarness._log.warning('Unexpected can_use_tool request while permissions are skipped');
          final toolUseId = data['tool_use_id'] as String?;
          _writeControlLine(_adapter.buildApprovalResponse(requestId, allow: false, toolUseId: toolUseId));
          return;
        }

        final toolUseId = data['tool_use_id'] as String?;
        final context = activeTurnContext;
        if (context?.allowOperatorApproval ?? false) {
          if (_pendingOperatorApprovals.containsKey(requestId)) {
            _writeControlLine(_adapter.buildApprovalResponse(requestId, allow: false, toolUseId: toolUseId));
            return;
          }
          final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
          final timer = Timer(expiresAt.difference(DateTime.now().toUtc()), () {
            _declineOperatorApproval(requestId, expired: true);
          });
          _pendingOperatorApprovals[requestId] = (turnId: context!.turnId, toolUseId: toolUseId, timer: timer);
          final input = mapValue(data['input']) ?? mapValue(data['tool_input']) ?? const <String, dynamic>{};
          _emitControlEvent(
            ToolApprovalWaitEvent(
              requestId: requestId,
              toolName: stringValue(data['tool_name']) ?? 'tool',
              input: input,
              operatorActionable: true,
              expiresAt: expiresAt,
            ),
          );
          return;
        }

        final allow = toolPolicy == ToolApprovalPolicy.allowAll;
        _writeControlLine(_adapter.buildApprovalResponse(requestId, allow: allow, toolUseId: toolUseId));
        return;

      case 'hook_callback':
        await _handleHookCallback(requestId, data);
        return;

      case 'mcp_message':
        await _handleMcpMessage(requestId, data);
        return;

      default:
        _writeControlLine(_adapter.buildGenericResponse(requestId));
        return;
    }
  }
}
