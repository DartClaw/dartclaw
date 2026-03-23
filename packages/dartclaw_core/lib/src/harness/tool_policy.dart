/// Governs how tool-use requests are handled.
///
/// Phase 0 only supports [allowAll]; finer-grained policies (allowlist,
/// interactive prompt, etc.) will be added in later phases.
///
/// Retained for compatibility with existing harness configuration and possible
/// future Codex approval-policy work. Claude now relies on hook callbacks
/// rather than `can_use_tool` permission prompts.
enum ToolApprovalPolicy { allowAll }

/// Builds a `control_response` for a `can_use_tool` control_request.
///
/// When [allow] is `true` the tool proceeds; when `false` it is denied.
/// [toolUseId] is forwarded when present in the original request.
Map<String, dynamic> buildToolResponse(String requestId, {required bool allow, String? toolUseId}) {
  return {
    'type': 'control_response',
    'response': {
      'subtype': 'success',
      'request_id': requestId,
      'response': {'behavior': allow ? 'allow' : 'deny', 'toolUseID': ?toolUseId},
    },
  };
}

/// Builds a `control_response` for a `hook_callback` control_request.
///
/// When [allow] is `true` the hook permits the tool; when `false` it denies.
Map<String, dynamic> buildHookResponse(String requestId, {required bool allow}) {
  return {
    'type': 'control_response',
    'response': {
      'subtype': 'success',
      'request_id': requestId,
      'response': {
        'continue': true,
        'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': allow ? 'allow' : 'deny'},
      },
    },
  };
}

/// Builds a generic success `control_response` for unrecognised subtypes.
Map<String, dynamic> buildGenericResponse(String requestId) {
  return {
    'type': 'control_response',
    'response': {'subtype': 'success', 'request_id': requestId, 'response': <String, dynamic>{}},
  };
}
