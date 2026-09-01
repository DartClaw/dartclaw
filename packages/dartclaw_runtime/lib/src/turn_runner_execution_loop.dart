part of 'turn_runner.dart';

/// A stream fault – a bounded-output kill or an undecodable provider stream –
/// is the provider failure a caller must be able to tell apart from an ordinary
/// crash, so its description survives the otherwise opaque failure message.
///
/// A turn that outran its wall-clock budget is the same kind of thing: the
/// remedy is a budget, not a retry, and reading the generic message left a live
/// investigation reconstructing the cause from raw harness logs.
String _turnFailureMessage(Object error) => switch (error) {
  UnsupportedHarnessCapabilityException() => error.toString(),
  ProcessOutputLimitException() => error.message,
  ProcessStreamException() => error.message,
  TimeoutException() => error.message ?? 'Turn timed out',
  _ => 'Turn execution failed',
};

extension _TurnRunnerExecutionLoop on TurnRunner {
  Future<void> _runTurnInner({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
  }) async {
    final buffer = StringBuffer();
    final stopwatch = Stopwatch()..start();
    final turnPolicy = _activeTurns[sessionId];
    _installTurnPolicy(sessionId, turnId, turnPolicy?.allowedTools, turnPolicy?.readOnly ?? false);
    var progressTextLength = 0;
    TurnLivenessTracker? runtimeWait;
    final pendingApprovalIds = <String>{};

    void recordActivity(TurnWaitReason reason) {
      runtimeWait?.recordActivity(pendingApprovalIds.isEmpty ? reason : TurnWaitReason.toolApproval);
    }

    late final TurnToolHookCallbackHandler toolHooks;
    TurnProgressSnapshot buildSnapshot() => TurnProgressSnapshot(
      elapsed: stopwatch.elapsed,
      toolCallCount: toolHooks.toolCallCount,
      lastToolName: toolHooks.lastToolName,
      textLength: progressTextLength,
    );
    toolHooks = TurnToolHookCallbackHandler(
      sessionId: sessionId,
      turnId: turnId,
      governanceEnforcer: _governanceEnforcer,
      resetService: _resetService,
      recordProgress: () => recordActivity(TurnWaitReason.unknown),
      loopAction: _loopAction,
      buildSnapshot: buildSnapshot,
      emitProgressEvent: _progressController.add,
      onLoopAbort: (detection) {
        _loopDetectedTurns[turnId] = detection;
        unawaited(cancelTurnById(sessionId, turnId, TurnCancelReason.automationCancel, enforceCanCancel: false));
      },
    );
    _turnToolHooks[turnId] = toolHooks;
    _turnProgressSnapshots[sessionId] = buildSnapshot;

    String? userMessageFull;
    if (messages.isNotEmpty) {
      final last = messages.last;
      if (last['role'] == 'user') {
        userMessageFull = last['content'] as String?;
      }
    }
    final userMessage = userMessageFull != null ? truncate(userMessageFull, 100, suffix: '...') : null;

    final eventSub = _worker.events.listen((event) {
      if (event is DeltaEvent) {
        buffer.write(event.text);
        recordActivity(TurnWaitReason.unknown);
        _resetService?.touchActivity(sessionId);
        progressTextLength += event.text.length;
        _progressController.add(TextDeltaProgressEvent(snapshot: buildSnapshot(), text: event.text));
      } else if (event is ToolUseEvent) {
        toolHooks.handleToolUse(event);
      } else if (event is ToolResultEvent) {
        toolHooks.handleToolResult(event);
      } else if (event is ToolApprovalWaitEvent) {
        pendingApprovalIds.add(event.requestId);
        recordActivity(TurnWaitReason.toolApproval);
      } else if (event is ToolApprovalResolvedEvent) {
        pendingApprovalIds.remove(event.requestId);
        recordActivity(TurnWaitReason.unknown);
      } else if (event is ProviderProgressBridgeEvent) {
        recordActivity(TurnWaitReason.providerTurn);
        _resetService?.touchActivity(sessionId);
        _progressController.add(ProviderProgressEvent(snapshot: buildSnapshot(), kind: event.kind, text: event.text));
      } else if (event is SystemInitEvent) {
        recordActivity(TurnWaitReason.unknown);
        _contextMonitor.update(contextWindow: event.contextWindow);
      } else if (event is CompactionStartingBridgeEvent) {
        _eventBus?.fire(CompactionStartingEvent(sessionId: sessionId, trigger: 'auto', timestamp: DateTime.now()));
      } else if (event is CompactionCompletedBridgeEvent) {
        _eventBus?.fire(CompactionCompletedEvent(sessionId: sessionId, trigger: 'auto', timestamp: DateTime.now()));
      }
    });

    TurnOutcome? outcome;
    Timer? statusTickTimer;
    Timer? turnTimeoutTimer;
    try {
      try {
        final guardOutcome = await _guardEvaluator.evaluateMessageReceived(
          turnId: turnId,
          sessionId: sessionId,
          source: source,
          userMessageFull: userMessageFull,
        );
        if (guardOutcome != null) {
          outcome = guardOutcome;
          return;
        }

        final systemPrompt = await _buildSystemPrompt(sessionId);
        final turnCtx = _activeTurns[sessionId];
        await _awaitAcceptedCancelRecovery(sessionId);
        if (_externallyCompletedTurns.contains(turnId)) {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            completedAt: DateTime.now(),
          );
          return;
        }
        TurnRunner._log.info(
          'Turn start: session=$sessionId, turn=$turnId, '
          'provider=$providerId${userMessage != null ? ', prompt=$userMessage' : ''}',
        );
        statusTickTimer = _statusTickInterval > Duration.zero
            ? Timer.periodic(_statusTickInterval, (_) {
                _progressController.add(StatusTickProgressEvent(snapshot: buildSnapshot()));
              })
            : null;
        final effectiveTurnTimeout = turnCtx?.turnTimeout ?? _turnLimits.turnTimeout;
        final effectiveStallTimeout =
            effectiveTurnTimeout > Duration.zero && effectiveTurnTimeout <= _turnLimits.stallTimeout
            ? Duration.zero
            : _turnLimits.stallTimeout;
        runtimeWait = TurnLivenessTracker(
          stallTimeout: effectiveStallTimeout,
          timerFactory: _livenessTimerFactory,
          now: _livenessNow,
          initialReason: TurnWaitReason.unknown,
          onWaiting: () => _emitWaitState(sessionId, TurnWaitState.waiting),
          onStuck: () => _emitWaitState(sessionId, TurnWaitState.stuck),
          onStall: (budget) => _handleTurnStall(sessionId: sessionId, turnId: turnId, stallTimeout: budget),
        );
        _runtimeWaits[sessionId] = runtimeWait;
        if (effectiveTurnTimeout > Duration.zero) {
          turnTimeoutTimer = _livenessTimerFactory(
            effectiveTurnTimeout,
            () => _handleTurnTimeout(sessionId: sessionId, turnId: turnId, turnTimeout: effectiveTurnTimeout),
          );
        }
        late final TurnResult result;
        try {
          if (_worker case final HarnessTurnContextSink sink) {
            sink.setTurnContext(
              HarnessTurnContext(
                sessionId: sessionId,
                turnId: turnId,
                source: source,
                agentName: turnCtx?.agentName ?? 'main',
                turnTimeout: effectiveTurnTimeout > Duration.zero
                    ? effectiveTurnTimeout + const Duration(seconds: 60)
                    : Duration.zero,
              ),
            );
          }
          result = await _worker.turn(
            sessionId: sessionId,
            agentId: TurnRunner._harnessAgentId(turnCtx?.agentName),
            messages: messages,
            systemPrompt: systemPrompt,
            directory: turnCtx?.directory,
            model: turnCtx?.model,
            effort: turnCtx?.effort,
            maxTurns: turnCtx?.maxTurns,
            outputSchema: turnCtx?.outputSchema,
            providerSessionId: turnCtx?.providerSessionId,
            requestProviderSessionResume: turnCtx?.requestProviderSessionResume ?? false,
          );
        } finally {
          if (_worker case final HarnessTurnContextSink sink) sink.setTurnContext(null);
          _postProviderTurns.add(turnId);
          runtimeWait.dispose();
          runtimeWait = null;
          _runtimeWaits.remove(sessionId);
          turnTimeoutTimer?.cancel();
        }
        if (_externallyCompletedTurns.remove(turnId)) {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            completedAt: DateTime.now(),
          );
          return;
        }
        final accumulated = buffer.toString();
        toolHooks.finalizePendingToolCalls();
        stopwatch.stop();
        TurnRunner._log.info(
          'Turn complete: session=$sessionId, turn=$turnId, '
          'provider=$providerId, ${stopwatch.elapsedMilliseconds}ms, '
          'tools=${toolHooks.toolCallCount}, text=${accumulated.length} chars',
        );
        final cacheReadTokens = _worker.supportsCachedTokens ? result.cacheReadTokens : 0;
        final cacheWriteTokens = _worker.supportsCachedTokens ? result.cacheWriteTokens : 0;

        try {
          await _trackSessionUsage(sessionId, result, providerId);
          await _applySessionMetadata(sessionId, result);
          // Zero reads as "no usage reported" here: a turn that reports none must not
          // zero the last known context size, and no provider measures a real context at 0.
          _contextMonitor.update(contextTokens: result.inputTokens > 0 ? result.inputTokens : null);
        } catch (e) {
          TurnRunner._log.warning('Failed to track usage', e);
        }

        final tracker = _usageTracker;
        if (tracker != null) {
          final turnCtx = _activeTurns[sessionId];
          final inputTokens = result.inputTokens;
          final outputTokens = result.outputTokens;
          final durationMs = turnCtx != null ? DateTime.now().difference(turnCtx.startedAt).inMilliseconds : 0;
          unawaited(
            tracker
                .record(
                  UsageEvent(
                    timestamp: DateTime.now(),
                    sessionId: sessionId,
                    agentName: turnCtx?.agentName ?? 'main',
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    durationMs: durationMs,
                  ),
                )
                .catchError((Object e) {
                  TurnRunner._log.fine('Failed to record usage', e);
                }),
          );

          // Post-hoc token velocity check (Mechanism 2).
          try {
            _governanceEnforcer.recordTokensAndCheckVelocity(sessionId, inputTokens + outputTokens);
            // Velocity detection post-hoc: fire warn event even in abort mode
            // (tokens already spent). Next pre-turn check will abort if still over.
          } catch (e) {
            TurnRunner._log.fine('Loop velocity check failed (non-fatal): $e');
          }
        }

        // Check context warning threshold (one-shot per session).
        try {
          if (_contextMonitor.checkThreshold(sessionId: sessionId)) {
            final percent = _contextMonitor.usagePercent ?? 0;
            _sseBroadcast?.broadcast('context_warning', {
              'sessionId': sessionId,
              'usagePercent': percent,
              'message':
                  'Context window $percent% used — consider starting '
                  'a new session or saving context to memory.',
            });
          }
        } catch (e) {
          TurnRunner._log.fine('Failed to emit context warning: $e');
        }

        if (result.isError) {
          final rawProviderError = result.error;
          final providerError = rawProviderError != null && rawProviderError.trim().isNotEmpty
              ? rawProviderError.trim()
              : 'Provider turn failed';
          final sendOutcome = await _guardEvaluator.evaluateBeforeAgentSend(
            turnId: turnId,
            sessionId: sessionId,
            accumulated: providerError,
            toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
            toolCallCount: toolHooks.toolCallCount,
            failedToolCallCount: toolHooks.failedToolCallCount,
          );
          if (sendOutcome != null) {
            outcome = sendOutcome;
            return;
          }
          final redactedProviderError = _redactor?.redact(providerError) ?? providerError;
          await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: redactedProviderError);
          await _sessions?.touchUpdatedAt(sessionId);
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.failed,
            errorMessage: redactedProviderError,
            providerSessionId: result.providerSessionId,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            turnDuration: stopwatch.elapsed,
            toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
            toolCallCount: toolHooks.toolCallCount,
            failedToolCallCount: toolHooks.failedToolCallCount,
            completedAt: DateTime.now(),
          );
          return;
        }

        // The provider's own final text wins over the delta stream when it
        // reports one: a turn that completes several agent messages streams
        // their deltas interleaved, so the accumulation is not the answer.
        final streamedOrFinal = result.finalText ?? accumulated;
        final responseContent = result.structuredOutput == null || result.isCancelled
            ? streamedOrFinal
            : jsonEncode(result.structuredOutput);
        if (responseContent.isNotEmpty) {
          final sendOutcome = await _guardEvaluator.evaluateBeforeAgentSend(
            turnId: turnId,
            sessionId: sessionId,
            accumulated: responseContent,
            toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
            toolCallCount: toolHooks.toolCallCount,
            failedToolCallCount: toolHooks.failedToolCallCount,
          );
          if (sendOutcome != null) {
            outcome = sendOutcome;
            return;
          }
        }

        if (result.isCancelled) {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            providerSessionId: result.providerSessionId,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            turnDuration: stopwatch.elapsed,
            toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
            toolCallCount: toolHooks.toolCallCount,
            failedToolCallCount: toolHooks.failedToolCallCount,
            completedAt: DateTime.now(),
          );
          return;
        }

        final persistedResponse = _redactor?.redact(responseContent) ?? responseContent;
        await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: persistedResponse);
        await _sessions?.touchUpdatedAt(sessionId);
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: TurnStatus.completed,
          responseText: persistedResponse,
          structuredOutput: result.structuredOutput,
          providerSessionId: result.providerSessionId,
          inputTokens: result.inputTokens,
          outputTokens: result.outputTokens,
          cacheReadTokens: cacheReadTokens,
          cacheWriteTokens: cacheWriteTokens,
          turnDuration: stopwatch.elapsed,
          toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
          toolCallCount: toolHooks.toolCallCount,
          failedToolCallCount: toolHooks.failedToolCallCount,
          completedAt: DateTime.now(),
        );

        try {
          await _appendDailyLog(
            sessionId: sessionId,
            source: source,
            userMessage: userMessageFull,
            toolEvents: toolHooks.toolEvents,
            toolEventCount: toolHooks.toolCallCount,
            result: accumulated,
          );
        } catch (e) {
          TurnRunner._log.warning('Failed to write daily log', e);
        }

        if (_contextMonitor.shouldFlushForCompactionSignal(compactionSignalAvailable: _worker.supportsPreCompactHook)) {
          try {
            await _runFlushTurn(sessionId);
          } catch (e) {
            TurnRunner._log.warning('Pre-compaction flush failed (lossy compaction possible)', e);
          }
        }
      } catch (e, st) {
        final wasCancelled = _cancelledTurns.remove(turnId);
        _cancellingTurns.remove(turnId);
        final acceptedCancel =
            _acceptedCancelCleanupPending.contains(turnId) || _externallyCompletedTurns.contains(turnId);
        final loopDetection = _loopDetectedTurns.remove(turnId);
        if (wasCancelled) {
          TurnRunner._log.info('Turn $turnId cancelled');
        } else {
          TurnRunner._log.warning('Turn $turnId failed', e, st);
        }
        if (!acceptedCancel) {
          try {
            var partial = buffer.toString();
            if (partial.isNotEmpty && _redactor != null) {
              partial = _redactor.redact(partial);
            }
            // Post loop detection message if this was a loop-cancelled turn.
            final loopMsg = loopDetection != null ? '[Loop detected: ${loopDetection.message}]' : null;
            await _messages.insertMessage(
              sessionId: sessionId,
              role: 'assistant',
              content:
                  loopMsg ?? (partial.isNotEmpty ? partial : (wasCancelled ? '[Turn cancelled]' : '[Turn failed]')),
            );
          } catch (e) {
            TurnRunner._log.warning('Failed to persist partial message after turn failure: $e');
          }
        }
        toolHooks.finalizePendingToolCalls();
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: wasCancelled ? TurnStatus.cancelled : TurnStatus.failed,
          errorMessage: wasCancelled ? null : _turnFailureMessage(e),
          turnDuration: stopwatch.elapsed,
          toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
          toolCallCount: toolHooks.toolCallCount,
          failedToolCallCount: toolHooks.failedToolCallCount,
          completedAt: DateTime.now(),
          loopDetection: loopDetection,
        );
        if (!acceptedCancel) {
          unawaited(
            _selfImprovement?.appendError(
              errorType: wasCancelled ? 'TURN_CANCELLED' : 'TURN_FAILURE',
              sessionId: sessionId,
              context: '$e',
            ),
          );
        }
      }
    } finally {
      _clearTurnPolicy(sessionId, turnId);
      statusTickTimer?.cancel();
      turnTimeoutTimer?.cancel();
      await eventSub.cancel();
      final activeStillThisTurn = _activeTurns[sessionId]?.turnId == turnId;
      final cancelCleanupPending = _acceptedCancelCleanupPending.contains(turnId);
      if (activeStillThisTurn) {
        _turnProgressSnapshots.remove(sessionId);
        _runtimeWaits.remove(sessionId)?.dispose();
      }
      final recentTaskId = activeStillThisTurn ? _activeTurns[sessionId]?.taskId : _recentTaskIds[turnId];
      final resolved =
          outcome ??
          TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.failed,
            errorMessage: 'Unexpected internal error',
            completedAt: DateTime.now(),
          );
      if (!cancelCleanupPending) {
        _rememberRecentOutcome(resolved, taskId: recentTaskId);
        _outcomePending.remove(turnId)?.complete(resolved);
      }
      if (activeStillThisTurn && !cancelCleanupPending) {
        switch (resolved.status) {
          case TurnStatus.completed:
            _emitWaitState(sessionId, TurnWaitState.completed);
          case TurnStatus.failed:
            _emitWaitState(sessionId, TurnWaitState.failed);
          case TurnStatus.cancelled:
            _emitWaitState(sessionId, TurnWaitState.cancelled);
        }
      }
      // Normal completion and cancellation inspect this set before finally; this
      // unconditional removal also covers throw and early-return paths.
      _externallyCompletedTurns.remove(turnId);
      _postProviderTurns.remove(turnId);
      _turnToolHooks.remove(turnId);
      if (!cancelCleanupPending) _cancellingTurns.remove(turnId);
      if (activeStillThisTurn && !cancelCleanupPending) {
        _activeTurns.remove(sessionId);
        if (!_externallyAdmittedTurns.contains(turnId)) _lockManager.release(sessionId);
      }
      _governanceEnforcer.cleanupTurn(turnId);

      final turnState = _turnState;
      if (turnState != null && activeStillThisTurn && !cancelCleanupPending) {
        unawaited(
          turnState.delete(sessionId).catchError((Object e, StackTrace st) {
            TurnRunner._log.warning('Failed to clean up turn state', e, st);
          }),
        );
      }
      _acceptedCancelCleanupPending.remove(turnId);
    }
  }
}
