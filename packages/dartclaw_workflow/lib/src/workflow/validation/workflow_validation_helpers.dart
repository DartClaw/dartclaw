part of '../workflow_definition_validator.dart';

// `_err` records both errors and warnings; pass the target diagnostics list.
WorkflowValidationError _err(WorkflowValidationErrorType type, String message, {String? stepId, String? loopId}) =>
    WorkflowValidationError(message: message, type: type, stepId: stepId, loopId: loopId);

WorkflowValidationError _refErr(String? stepId, String message) =>
    WorkflowValidationError(message: message, type: WorkflowValidationErrorType.invalidReference, stepId: stepId);

WorkflowValidationError _contextErr(String? stepId, String message) =>
    WorkflowValidationError(message: message, type: WorkflowValidationErrorType.contextInconsistency, stepId: stepId);

WorkflowValidationError _timeoutErr(String subject, (String, String, String) invalid, [String? stepId]) => _err(
  WorkflowValidationErrorType.hybridStepConstraint,
  '$subject uses ${invalid.$1} for ${invalid.$2} step; use ${invalid.$3}.',
  stepId: stepId,
);
