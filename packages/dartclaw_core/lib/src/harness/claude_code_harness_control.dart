part of 'claude_code_harness.dart';

extension _ClaudeCodeHarnessControl on ClaudeCodeHarness {
  Future<void> _handlePreToolUseCallback(String requestId, Map<String, dynamic> hookInput) async {
    final rawToolName = hookInput['tool_name'] as String;
    _emitControlEvent(ToolApprovalWaitEvent(requestId: requestId, toolName: rawToolName));
    final toolInput = hookInput['tool_input'] as Map<String, dynamic>;
    final canonicalTool = _adapter.mapToolName(rawToolName);
    final guardToolName = canonicalTool?.stableName ?? 'claude:$rawToolName';

    if (canonicalTool == null) {
      ClaudeCodeHarness._log.warning('Falling back to unmapped Claude tool name: $rawToolName -> $guardToolName');
    }

    try {
      final chain = guardChain;
      if (chain != null) {
        final verdict = await chain.evaluateBeforeToolCall(
          guardToolName,
          toolInput,
          sessionId: _activeTurnSessionId,
          agentId: _activeAgentId,
          rawProviderToolName: rawToolName,
        );
        if (verdict.isBlock) {
          if (_tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: false))) {
            _emitControlEvent(ToolApprovalResolvedEvent(requestId: requestId));
          }
          return;
        }
      }
    } catch (error, stackTrace) {
      ClaudeCodeHarness._log.severe('Claude hook guard evaluation failed for $requestId: $error', error, stackTrace);
      if (_tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: false))) {
        _emitControlEvent(ToolApprovalResolvedEvent(requestId: requestId));
      }
      return;
    }

    final envMap = toolInput['env'] as Map<String, dynamic>?;
    if (envMap != null) {
      final strippedNames = _bashEnvCredentialNames.where(envMap.containsKey).toList();
      if (strippedNames.isNotEmpty) {
        final sanitizedEnv = Map<String, dynamic>.from(envMap)..removeWhere((name, _) => strippedNames.contains(name));
        final updatedInput = Map<String, dynamic>.from(toolInput)..['env'] = sanitizedEnv;
        ClaudeCodeHarness._log.info('Stripped ${strippedNames.join(', ')} from bash env');
        if (_tryWriteHookResponse(requestId, _adapter.buildCredentialStripResponse(requestId, updatedInput))) {
          _emitControlEvent(ToolApprovalResolvedEvent(requestId: requestId));
        }
        return;
      }
    }

    if (_tryWriteHookResponse(requestId, _adapter.buildHookResponse(requestId, allow: true))) {
      _emitControlEvent(ToolApprovalResolvedEvent(requestId: requestId));
    }
  }

  Future<ModelCatalogue> _discoverModelCatalogue() async {
    await start();
    try {
      final requestId = 'req_settings_${DateTime.now().millisecondsSinceEpoch}';
      final completer = Completer<Map<String, dynamic>>();
      _settingsRequest = (id: requestId, completer: completer);
      _writeControlLine(_adapter.buildGetSettingsRequest(requestId: requestId));
      final settings = await completer.future.timeout(_initializeTimeout);
      return claudeModelCatalogue(initialize: _initResponse ?? const {}, settings: settings);
    } finally {
      _settingsRequest = null;
      await stop();
    }
  }

  /// Consumes [line] when it answers the pending `get_settings` request.
  bool _completeSettingsRequest(String line) {
    final pending = _settingsRequest;
    if (pending == null || pending.completer.isCompleted) return false;
    final json = decodeJsonObject(line);
    if (json == null || stringValue(json['type']) != 'control_response') return false;
    if (stringValue(mapValue(json['response'])?['request_id']) != pending.id) return false;
    pending.completer.complete(json);
    return true;
  }

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
