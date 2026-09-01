import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory, HarnessRegistrar, HarnessRegistration;
import 'package:logging/logging.dart';

import 'acp_config.dart';
import 'acp_config_parser.dart';
import 'acp_container_admission.dart';
import 'acp_harness_registration.dart';
import 'acp_reverse_call_handlers.dart';
import 'acp_target_validation.dart';

final _log = Logger('AcpHarnessRegistrar');

/// Contributes the configured `harness.acp.agents` registrations to a runtime.
///
/// This is the only production seam by which ACP reaches a runtime: the runtime
/// package names neither this type nor anything else in `dartclaw_acp`, so a
/// deployment that does not compose this registrar registers no ACP provider,
/// emits no ACP diagnostic, and carries none of ACP's supply chain.
///
/// Two postures ride on this class and are enforced here rather than at the
/// harness:
///
/// - **Host-only, fail-closed.** [declare] refuses the whole assembly when any
///   registration requires a container boundary DartClaw cannot mediate. It
///   never downgrades one to host execution.
/// - **Credential isolation.** [HarnessRegistration.credentialOverlayFor]
///   presents only the API key the registration's own `credential:` names, so
///   no lane can resolve an ACP binary and then overlay a DartClaw-managed
///   provider credential onto it.
///
/// A registration's container profile is `harness.acp.agents.<id>.container_profile`
/// and nothing else — there is no code-declared default here that could outrank
/// what the operator configured.
final class AcpHarnessRegistrar implements HarnessRegistrar {
  static const _builtInProviderIds = {'claude', 'codex'};

  /// Creates a registrar, optionally reporting reverse-call decisions to
  /// [reverseCallAudit] instead of this package's own `fine` log.
  const new({AcpReverseCallAuditSink? reverseCallAudit}) : _reverseCallAudit = reverseCallAudit;

  final AcpReverseCallAuditSink? _reverseCallAudit;

  @override
  void primeConfigSections(DartclawConfig config) => acpConfigFor(config);

  @override
  HarnessRegistration declare(DartclawConfig config) {
    final agents = _normalizedAgents(config);
    final requirementErrors = [
      for (final entry in agents.entries) ?acpContainerRequirementError(entry.key, entry.value),
    ];
    if (requirementErrors.isNotEmpty) {
      throw StateError(requirementErrors.join('\n'));
    }
    return _registration(
      config: config,
      entries: {
        for (final entry in agents.entries)
          entry.key: ProviderEntry(
            executable: entry.value.binary,
            poolSize: config.providers[entry.key]?.poolSize ?? 0,
            options: const {'credentials_required': false},
          ),
      },
      toolPolicyWarnings: agents.isEmpty
          ? const []
          : const [
              'Tool-restricted agent or job turns are configured for an ACP harness – host tool-policy enforcement '
                  'covers only guard-evaluated reverse calls and permission requests',
            ],
    );
  }

  @override
  Future<HarnessRegistration> activate(DartclawConfig config, HarnessFactory factory) async {
    final agents = _normalizedAgents(config);
    final results = await _validateConfiguredTargets(config, agents);
    for (final entry in agents.entries) {
      if (results[entry.key]?.status != AcpTargetValidationStatus.passed) continue;
      factory.registerAcpAgent(entry.key, entry.value, reverseCallAudit: _reverseCallAudit ?? _logReverseCall);
    }
    return _registration(
      config: config,
      entries: {
        for (final entry in agents.entries)
          entry.key: _refinedEntry(config, entry.key, entry.value, results[entry.key]),
      },
    );
  }

  HarnessRegistration _registration({
    required DartclawConfig config,
    required Map<String, ProviderEntry> entries,
    List<String> toolPolicyWarnings = const [],
  }) {
    // Both lookups resolve through `AcpConfig.operator []` rather than the
    // normalized map above, so a post-normalization collision raises there
    // instead of silently answering for one of the two colliding agents.
    final acp = acpConfigFor(config);
    return HarnessRegistration(
      providerEntries: entries,
      containerProfileFor: (providerId) => acpDeclaredContainerProfileFor(config, providerId),
      credentialOverlayFor: (providerId, environment) =>
          overlayAcpCredential(environment: environment, credentials: config.credentials, agent: acp[providerId]),
      toolPolicyWarnings: toolPolicyWarnings,
    );
  }

  /// The registrations keyed by canonical provider identity.
  ///
  /// Raises rather than picking a winner when two configured ids normalize to
  /// the same identity.
  Map<String, AcpAgentConfig> _normalizedAgents(DartclawConfig config) {
    final agents = ProviderIdentity.normalizeKeys(acpConfigFor(config).agents, subject: 'Configured ACP provider IDs');
    final reserved = agents.keys.where(_builtInProviderIds.contains).toList(growable: false);
    if (reserved.isNotEmpty) {
      throw StateError(
        reserved.map((providerId) => 'Invalid harness.acp.agents.$providerId: provider ID is built in').join('\n'),
      );
    }
    return agents;
  }

  ProviderEntry _refinedEntry(
    DartclawConfig config,
    String providerId,
    AcpAgentConfig agent,
    AcpTargetValidationResult? validation,
  ) {
    final validationJson = validation?.toJson();
    return ProviderEntry(
      executable: agent.binary,
      poolSize: validation?.status == AcpTargetValidationStatus.passed
          ? config.providers[providerId]?.poolSize ?? 0
          : 0,
      options: {
        'credentials_required': false,
        ...validationJson == null ? const <String, dynamic>{} : {'registration_validation_result': validationJson},
        if (validationJson != null) 'registration_validation_owned': true,
      },
    );
  }

  Future<Map<String, AcpTargetValidationResult>> _validateConfiguredTargets(
    DartclawConfig config,
    Map<String, AcpAgentConfig> agents,
  ) async {
    if (agents.isEmpty) {
      return const {};
    }
    const validator = AcpTargetValidator();
    final defaultProviderId = ProviderIdentity.normalize(config.agent.provider);
    final capabilityFlags = AcpReverseCallHandlers().capabilityFlags;
    final advertisedCapabilities = {
      if (capabilityFlags['readTextFile'] == true || capabilityFlags['writeTextFile'] == true) 'fs',
      if (capabilityFlags['terminal'] == true) 'terminal',
    };
    final results = await validator.validateConfiguredTargets(
      agents: agents,
      commandProbe: Process.run,
      advertisedCapabilities: {for (final providerId in agents.keys) providerId: advertisedCapabilities},
      requiredTargets: agents.entries
          .where((entry) => entry.key == defaultProviderId || entry.value.requiresGuardMediation)
          .map((entry) => entry.key)
          .toSet(),
    );
    final failures = results.entries.where(
      (entry) =>
          entry.value.status == AcpTargetValidationStatus.failed && agents[entry.key]?.requiresGuardMediation == true,
    );
    if (failures.isNotEmpty) {
      throw StateError(
        failures
            .map((entry) => 'Invalid harness.acp.agents.${entry.key}: ${entry.value.message ?? entry.value.errorCode}')
            .join('\n'),
      );
    }
    return results;
  }

  static void _logReverseCall(AcpReverseCallAuditEvent event) {
    _log.fine(
      'ACP reverse-call raw=${event.rawProviderToolName}'
      '${event.canonicalToolName == null ? '' : ' canonical=${event.canonicalToolName}'}',
    );
  }
}

/// Returns the container profile an ACP registration declares for [providerId].
///
/// This is the ACP-owned mapping injected into `ExecutionPolicyResolver`; the
/// runtime stays free of ACP types and profile-name knowledge.
String? acpDeclaredContainerProfileFor(DartclawConfig config, String providerId) =>
    switch (acpConfigFor(config)[providerId]?.containerProfile) {
      AcpContainerProfile.restricted => 'restricted',
      AcpContainerProfile.workspace => 'workspace',
      null => null,
    };

/// The spawn environment an ACP registration presents, given [environment].
///
/// An agent's `model_provider` selects no credential, so `credential:` is the
/// one injection path — and it can only carry an API-key entry whose YAML
/// captured a `${VAR}` reference to present it under. Config load warns about
/// every other shape and drops the reference, so this then overlays nothing.
Map<String, String> overlayAcpCredential({
  required Map<String, String> environment,
  required CredentialsConfig credentials,
  required AcpAgentConfig? agent,
}) {
  final name = agent?.credential;
  if (name == null) return environment;
  final entry = credentials[name];
  if (entry == null || !entry.isApiKeyCredential || !entry.isPresent) return environment;
  for (final envVar in entry.envVars) {
    environment[envVar] = entry.apiKey;
  }
  return environment;
}
