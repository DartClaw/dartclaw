/// Agent Client Protocol support for DartClaw — the ACP harness and its stdio
/// JSON-RPC client, the `harness.acp` config section, and the registrar that
/// composes both into a runtime.
library;

export 'src/acp_client.dart' show AcpClient, AcpPromptResult;
export 'src/acp_config.dart'
    show
        AcpAgentConfig,
        AcpAgentTopology,
        AcpConfig,
        AcpContainerProfile,
        AcpSecurityClassification,
        AcpVerifiedTargetProfile;
export 'src/acp_config_parser.dart' show acpConfigFor;
export 'src/acp_container_admission.dart' show acpContainerRequirementError;
export 'src/acp_errors.dart' show AcpHarnessErrorCode, AcpHarnessException;
export 'src/acp_harness.dart' show AcpHarness;
export 'src/acp_harness_registrar.dart' show AcpHarnessRegistrar, acpDeclaredContainerProfileFor, overlayAcpCredential;
export 'src/acp_harness_registration.dart' show AcpHarnessRegistration, acpPermissionDecision;
export 'src/acp_protocol_adapter.dart' show AcpProtocolAdapter;
export 'src/acp_reverse_call_handlers.dart'
    show
        AcpPermissionDecision,
        AcpPermissionRequest,
        AcpPermissionResult,
        AcpReverseCallAuditEvent,
        AcpReverseCallAuditSink,
        AcpReverseCallHandlers;
export 'src/acp_target_validation.dart'
    show
        AcpTargetEvidenceStatus,
        AcpTargetOperation,
        AcpTargetOperationEvidence,
        AcpTargetProbe,
        AcpTargetValidationResult,
        AcpTargetValidationStatus,
        AcpTargetValidator,
        acpSecurityClassificationId;
export 'src/ndjson_channel.dart' show ndjsonChannel;
