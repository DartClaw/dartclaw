import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'acp_config.dart';
import 'acp_harness.dart';
import 'acp_reverse_call_handlers.dart';

/// Registers configured ACP agents on a [HarnessFactory].
extension AcpHarnessRegistration on HarnessFactory {
  /// Registers a configured ACP agent as a provider identity.
  ///
  /// A supplied container manager is required authority, never an optional
  /// optimization: it is honored or the construction fails. No ACP container
  /// combination is mediated, so honoring one is impossible and a supplied
  /// manager fails closed rather than being discarded so the process silently
  /// lands on the host.
  ///
  /// The permission decision is derived from the constructed runner's own
  /// [GuardChain], so concurrent runners keep independent per-turn tool
  /// filters; a runner with no chain gets no decision callback and the harness
  /// falls back to its own default. [reverseCallAudit] is the composition
  /// root's diagnostic sink.
  void registerAcpAgent(String providerId, AcpAgentConfig agent, {AcpReverseCallAuditSink? reverseCallAudit}) {
    registerFirstClaim(providerId, (config) {
      if (agent.containerIsolationRequired && config.containerManager == null) {
        throw StateError('ACP provider "$providerId" requires container isolation but no container manager is wired');
      }
      if (config.containerManager != null) {
        throw StateError(
          'ACP provider "$providerId" was given a container manager, but DartClaw provides no container '
          'provider-credential or host-capability mediation for an ACP client. Select host execution for it.',
        );
      }
      final guardChain = config.guardChain;
      return AcpHarness(
        cwd: config.cwd,
        executable: agent.binary,
        arguments: agent.args,
        turnTimeout: config.turnTimeout,
        historyConfig: config.historyConfig,
        processFactory: config.processFactory,
        environment: config.environment,
        guardChain: guardChain,
        permissionDecision: guardChain == null ? null : (request) => acpPermissionDecision(guardChain, request),
        onReverseCallAudit: reverseCallAudit,
        platformCapabilities: config.platformCapabilities,
      );
    });
  }
}

/// Evaluates an ACP reverse-call permission request against [runnerGuardChain].
///
/// A guard evaluation that throws denies the request: an ACP client asking for
/// permission must not proceed on an unanswered question.
Future<AcpPermissionResult> acpPermissionDecision(GuardChain runnerGuardChain, AcpPermissionRequest request) async {
  try {
    final verdict = await runnerGuardChain.evaluateBeforeToolCall(
      request.operation,
      request.params,
      sessionId: request.sessionId,
      agentId: request.agentId,
      rawProviderToolName: 'session/request_permission',
    );
    return AcpPermissionResult(granted: !verdict.isBlock, reason: verdict.message);
  } catch (error) {
    return AcpPermissionResult(granted: false, reason: 'Permission evaluation failed: $error');
  }
}
