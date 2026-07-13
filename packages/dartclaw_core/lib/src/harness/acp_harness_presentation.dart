part of 'acp_harness.dart';

extension _AcpHarnessPresentation on AcpHarness {
  Duration _remainingUntil(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  void _emitProtocolMessages(List<proto.ProtocolMessage> messages) {
    for (final message in messages) {
      switch (message) {
        case proto.TextDelta(:final text):
          _eventsController.add(DeltaEvent(text));
        case proto.ToolUse(:final name, :final id, :final input):
          _eventsController.add(ToolUseEvent(toolName: name, toolId: id, input: input));
        case proto.ToolResult(:final toolId, :final output, :final isError):
          _eventsController.add(ToolResultEvent(toolId: toolId, output: output, isError: isError));
        case proto.ProgressMessage(:final text, :final kind):
          AcpHarness._log.fine('ACP progress $kind: $text');
          _eventsController.add(ProviderProgressBridgeEvent(kind: kind, text: text));
        case proto.SessionMetadataUpdate(:final title, :final metadata):
          _recordSessionMetadata(title: title, metadata: metadata);
        case proto.ProtocolDiagnostic(:final message, :final method, :final updateType):
          AcpHarness._log.fine(
            'ACP diagnostic${method == null ? '' : ' method=$method'}'
            '${updateType == null ? '' : ' update=$updateType'}: $message',
          );
        case proto.TurnComplete():
          break;
        case proto.SystemInit(:final contextWindow):
          if (contextWindow != null) {
            _eventsController.add(SystemInitEvent(contextWindow: contextWindow));
          }
        case proto.ControlRequest():
        case proto.CompactBoundary():
        case proto.CompactionStarted():
        case proto.CompactionCompleted():
          break;
      }
    }
  }

  void _handleSessionUpdate(Map<String, dynamic> update) {
    final completer = _activeTurnCompleter;
    if (_activeAcpSessionId == null || (completer != null && completer.isCompleted)) {
      AcpHarness._log.fine('Ignoring stale ACP session/update after turn cancellation or completion');
      return;
    }
    _emitProtocolMessages(_adapter.messagesForSessionUpdate(update));
  }

  void _handleMalformedLine(String line) {
    _emitProtocolMessages(_adapter.parseLine(line));
  }

  void _recordSessionMetadata({String? title, required Map<String, dynamic> metadata}) {
    if (title != null && title.trim().isNotEmpty) {
      _activeSessionTitle = title.trim();
    }
    _activeMetadata.addAll(metadata);
    _activeInputTokens = _intFromAcpMetadata(metadata, const ['input_tokens', 'inputTokens']) ?? _activeInputTokens;
    _activeOutputTokens = _intFromAcpMetadata(metadata, const ['output_tokens', 'outputTokens']) ?? _activeOutputTokens;
    _activeCacheReadTokens =
        _intFromAcpMetadata(metadata, const ['cache_read_tokens', 'cacheReadTokens']) ?? _activeCacheReadTokens;
    _activeCacheWriteTokens =
        _intFromAcpMetadata(metadata, const ['cache_write_tokens', 'cacheWriteTokens']) ?? _activeCacheWriteTokens;
  }

  void _resetActiveMetadata() {
    _activeMetadata.clear();
    _activeSessionTitle = null;
    _activeInputTokens = null;
    _activeOutputTokens = null;
    _activeCacheReadTokens = null;
    _activeCacheWriteTokens = null;
  }

  Map<String, Object?> _diagnostics({int? exitCode}) {
    final diagnostics = <String, Object?>{};
    if (exitCode != null) {
      diagnostics['exit_code'] = exitCode;
    }
    if (_stdoutDiagnostics.isNotEmpty) {
      diagnostics['stdout'] = _stdoutDiagnostics.toString();
    }
    if (_stderrDiagnostics.isNotEmpty) {
      diagnostics['stderr'] = _stderrDiagnostics.toString();
    }
    return diagnostics;
  }

  String _promptText(Object? content, String systemPrompt) {
    final text = switch (content) {
      String value => value,
      List<Object?> values => values.map((value) => '$value').join('\n'),
      null => '',
      _ => '$content',
    };
    if (systemPrompt.trim().isEmpty) {
      return text;
    }
    return '$systemPrompt\n\n$text';
  }
}

int? _intFromAcpMetadata(Map<String, dynamic> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
  }
  return null;
}
