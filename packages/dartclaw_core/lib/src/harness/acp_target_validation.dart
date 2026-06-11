import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart';

import 'acp_errors.dart';
import 'process_types.dart';

/// Executes a target-specific ACP probe and returns operation evidence.
typedef AcpTargetProbe =
    Future<Iterable<AcpTargetOperationEvidence>> Function(String providerId, AcpAgentConfig config);

/// Stable operation IDs reported by ACP target validation.
enum AcpTargetOperation {
  promptResponse('prompt_response', null),
  fileRead('file_read', 'fs/read_text_file'),
  fileWrite('file_write', 'fs/write_text_file'),
  terminalCreate('terminal_create', 'terminal/create'),
  sessionRequestPermission('session_request_permission', 'session/request_permission'),
  readBlocking('read_blocking', 'fs/read_text_file');

  /// Wire-format operation ID.
  final String id;

  /// Expected raw ACP method, when the operation proves a reverse-call path.
  final String? rawMethod;

  const AcpTargetOperation(this.id, this.rawMethod);

  /// Finds an operation by wire-format [id].
  static AcpTargetOperation? fromId(String id) {
    for (final operation in values) {
      if (operation.id == id) return operation;
    }
    return null;
  }
}

/// Security classification for one ACP target validation operation.
enum AcpTargetEvidenceStatus {
  guardMediated('guard_mediated'),
  containerIsolationOnly('container_isolation_only'),
  failed('failed'),
  skipped('skipped');

  /// Wire-format status.
  final String id;

  const AcpTargetEvidenceStatus(this.id);
}

/// Overall target validation status.
enum AcpTargetValidationStatus {
  passed('passed'),
  failed('failed'),
  skipped('skipped');

  /// Wire-format status.
  final String id;

  const AcpTargetValidationStatus(this.id);
}

/// Evidence for one ACP target operation.
final class AcpTargetOperationEvidence {
  /// Validated operation.
  final AcpTargetOperation operation;

  /// Operation security classification.
  final AcpTargetEvidenceStatus status;

  /// Raw ACP method observed for reverse-call proof.
  final String? rawMethod;

  /// Optional diagnostic detail.
  final String? detail;

  /// Creates operation evidence.
  const AcpTargetOperationEvidence({required this.operation, required this.status, this.rawMethod, this.detail});

  /// Whether this operation proves guard mediation.
  bool get isGuardMediated => status == AcpTargetEvidenceStatus.guardMediated;

  /// JSON-compatible operator-visible representation.
  Map<String, dynamic> toJson() => {
    'operation': operation.id,
    'status': status.id,
    if (rawMethod != null) 'rawMethod': rawMethod,
    if (detail != null) 'detail': detail,
  };
}

/// Target-level validation result consumed by routing/status surfaces.
final class AcpTargetValidationResult {
  /// Provider identity being validated.
  final String providerId;

  /// Overall validation status.
  final AcpTargetValidationStatus status;

  /// Topology-scoped security classification.
  final AcpSecurityClassification securityClassification;

  /// Operation evidence keyed by stable operation.
  final Map<AcpTargetOperation, AcpTargetOperationEvidence> evidence;

  /// Optional structured error code, such as `SPAWN_FAILED`.
  final String? errorCode;

  /// Optional diagnostic message.
  final String? message;

  /// Creates a target validation result.
  const AcpTargetValidationResult({
    required this.providerId,
    required this.status,
    required this.securityClassification,
    required this.evidence,
    this.errorCode,
    this.message,
  });

  /// True only when every required operation proved guard mediation.
  bool get isGuardMediated =>
      status == AcpTargetValidationStatus.passed &&
      securityClassification == AcpSecurityClassification.guardMediated &&
      AcpTargetOperation.values.every((operation) => evidence[operation]?.isGuardMediated ?? false);

  /// Creates a fully guard-mediated result for deterministic probes.
  factory AcpTargetValidationResult.guardMediated(String providerId) {
    return AcpTargetValidationResult(
      providerId: providerId,
      status: AcpTargetValidationStatus.passed,
      securityClassification: AcpSecurityClassification.guardMediated,
      evidence: {
        for (final operation in AcpTargetOperation.values)
          operation: AcpTargetOperationEvidence(
            operation: operation,
            status: AcpTargetEvidenceStatus.guardMediated,
            rawMethod: operation.rawMethod,
          ),
      },
    );
  }

  /// Creates a container-isolation-only result.
  factory AcpTargetValidationResult.containerIsolationOnly(String providerId, {String? message}) {
    return AcpTargetValidationResult(
      providerId: providerId,
      status: AcpTargetValidationStatus.passed,
      securityClassification: AcpSecurityClassification.containerIsolationOnly,
      message: message,
      evidence: {
        for (final operation in AcpTargetOperation.values)
          operation: AcpTargetOperationEvidence(
            operation: operation,
            status: AcpTargetEvidenceStatus.containerIsolationOnly,
            rawMethod: operation.rawMethod,
          ),
      },
    );
  }

  /// Creates a structured spawn-failed result for missing optional binaries.
  factory AcpTargetValidationResult.spawnFailed(String providerId, {required bool required, String? message}) {
    return AcpTargetValidationResult(
      providerId: providerId,
      status: required ? AcpTargetValidationStatus.failed : AcpTargetValidationStatus.skipped,
      securityClassification: AcpSecurityClassification.containerIsolationOnly,
      errorCode: AcpHarnessErrorCode.spawnFailed.code,
      message: message,
      evidence: {
        for (final operation in AcpTargetOperation.values)
          operation: AcpTargetOperationEvidence(
            operation: operation,
            status: AcpTargetEvidenceStatus.skipped,
            rawMethod: operation.rawMethod,
          ),
      },
    );
  }

  /// JSON-compatible operator-visible representation.
  Map<String, dynamic> toJson() => {
    'providerId': providerId,
    'status': status.id,
    'securityClassification': _classificationId(securityClassification),
    if (errorCode != null) 'errorCode': errorCode,
    if (message != null) 'message': message,
    'evidence': [for (final operation in AcpTargetOperation.values) evidence[operation]?.toJson()],
  };
}

/// Validates target configs and deterministic probe evidence for verified ACP targets.
final class AcpTargetValidator {
  /// Known verified target profiles.
  final Map<String, AcpVerifiedTargetProfile> profiles;

  /// Creates an ACP target validator.
  const AcpTargetValidator({this.profiles = AcpVerifiedTargetProfile.byProviderId});

  /// Validates static config proof requirements before subprocess spawn.
  List<String> validateConfig(
    String providerId,
    AcpAgentConfig config, {
    Set<String> advertisedCapabilities = const {},
  }) {
    final errors = <String>[];
    final profile = profiles[providerId];
    if (profile == null) {
      errors.add('Unknown ACP target "$providerId"');
      return errors;
    }
    final modelProvider = config.modelProvider?.trim().toLowerCase();
    if (config.requiresGuardMediation) {
      if (config.topology != AcpAgentTopology.direct) {
        errors.add('requires_guard_mediation requires topology "direct"');
      }
      if (modelProvider == null || modelProvider.isEmpty) {
        errors.add('requires_guard_mediation requires model_provider');
      } else if (profile.knownRelaySelectors.contains(modelProvider)) {
        errors.add('model_provider "$modelProvider" is an ACP relay selector');
      }
      if (config.verification == null || config.verification!.trim().isEmpty) {
        errors.add('requires_guard_mediation requires verification');
      }
      for (final builtin in profile.requiredBuiltins) {
        final lower = builtin.toLowerCase();
        final declared = {
          ...config.requiredBuiltins.map((value) => value.toLowerCase()),
          ...config.args.map((value) => value.toLowerCase()),
        };
        if (!declared.contains(lower)) {
          errors.add('guarded $providerId requires $builtin builtin');
        }
      }
      if (profile.requiresFsCapability && !advertisedCapabilities.contains('fs')) {
        errors.add('guarded $providerId requires advertised fs capability');
      }
      if (profile.requiresTerminalCapability && !advertisedCapabilities.contains('terminal')) {
        errors.add('guarded $providerId requires advertised terminal capability');
      }
    }
    return errors;
  }

  /// Verifies read-blocking evidence: denied reads must not disclose content.
  AcpTargetOperationEvidence readBlockingEvidence({
    required bool denied,
    required Map<String, dynamic> response,
    required String rawMethod,
  }) {
    final withheldContent = !response.containsKey('content') && !response.containsKey('text');
    return AcpTargetOperationEvidence(
      operation: AcpTargetOperation.readBlocking,
      rawMethod: rawMethod,
      status: denied && withheldContent && rawMethod == 'fs/read_text_file'
          ? AcpTargetEvidenceStatus.guardMediated
          : AcpTargetEvidenceStatus.failed,
    );
  }

  /// Probes configured targets, isolating missing optional binaries per target.
  Future<Map<String, AcpTargetValidationResult>> validateConfiguredTargets({
    required Map<String, AcpAgentConfig> agents,
    required CommandProbe commandProbe,
    AcpTargetProbe? targetProbe,
    Set<String> requiredTargets = const {},
    Map<String, Set<String>> advertisedCapabilities = const {},
  }) async {
    final results = <String, AcpTargetValidationResult>{};
    for (final entry in agents.entries) {
      final providerId = entry.key;
      final config = entry.value;
      final configErrors = validateConfig(
        providerId,
        config,
        advertisedCapabilities: advertisedCapabilities[providerId] ?? const {},
      );
      if (configErrors.isNotEmpty) {
        results[providerId] = AcpTargetValidationResult(
          providerId: providerId,
          status: AcpTargetValidationStatus.failed,
          securityClassification: AcpSecurityClassification.containerIsolationOnly,
          message: configErrors.join('; '),
          evidence: _evidenceForStatus(AcpTargetEvidenceStatus.failed),
        );
        continue;
      }
      try {
        final probe = await commandProbe(config.binary, const ['--version']);
        if (probe.exitCode != 0) {
          results[providerId] = AcpTargetValidationResult.spawnFailed(
            providerId,
            required: requiredTargets.contains(providerId),
            message: 'ACP binary "${config.binary}" did not start',
          );
          continue;
        }
      } catch (_) {
        results[providerId] = AcpTargetValidationResult.spawnFailed(
          providerId,
          required: requiredTargets.contains(providerId),
          message: 'ACP binary "${config.binary}" was not found',
        );
        continue;
      }
      if (!config.requiresGuardMediation) {
        results[providerId] = AcpTargetValidationResult.containerIsolationOnly(providerId);
        continue;
      }
      final probe = targetProbe;
      if (probe == null) {
        results[providerId] = AcpTargetValidationResult(
          providerId: providerId,
          status: AcpTargetValidationStatus.failed,
          securityClassification: AcpSecurityClassification.containerIsolationOnly,
          message: 'Guard-mediated ACP target requires operation probe evidence',
          evidence: _evidenceForStatus(AcpTargetEvidenceStatus.failed),
        );
        continue;
      }
      final evidence = {for (final item in await probe(providerId, config)) item.operation: item};
      final allOperationsGuardMediated = _allOperationsGuardMediated(evidence);
      final result = AcpTargetValidationResult(
        providerId: providerId,
        status: allOperationsGuardMediated ? AcpTargetValidationStatus.passed : AcpTargetValidationStatus.failed,
        securityClassification: allOperationsGuardMediated
            ? AcpSecurityClassification.guardMediated
            : AcpSecurityClassification.containerIsolationOnly,
        evidence: evidence,
      );
      results[providerId] = result;
    }
    return results;
  }
}

Map<AcpTargetOperation, AcpTargetOperationEvidence> _evidenceForStatus(AcpTargetEvidenceStatus status) {
  return {
    for (final operation in AcpTargetOperation.values)
      operation: AcpTargetOperationEvidence(operation: operation, status: status, rawMethod: operation.rawMethod),
  };
}

bool _allOperationsGuardMediated(Map<AcpTargetOperation, AcpTargetOperationEvidence> evidence) {
  return AcpTargetOperation.values.every((operation) => evidence[operation]?.isGuardMediated ?? false);
}

String acpSecurityClassificationId(AcpSecurityClassification classification) => _classificationId(classification);

String _classificationId(AcpSecurityClassification classification) {
  return switch (classification) {
    AcpSecurityClassification.guardMediated => 'guard_mediated',
    AcpSecurityClassification.containerIsolationOnly => 'container_isolation_only',
  };
}
