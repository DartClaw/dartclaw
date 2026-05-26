part of '../workflow_definition_validator.dart';

// `_err` records both errors and warnings; pass the target diagnostics list.
ValidationError _err(ValidationErrorType type, String message, {String? stepId, String? loopId}) =>
    ValidationError(message: message, type: type, stepId: stepId, loopId: loopId);

ValidationError _refErr(String? stepId, String message) =>
    ValidationError(message: message, type: ValidationErrorType.invalidReference, stepId: stepId);

ValidationError _contextErr(String? stepId, String message) =>
    ValidationError(message: message, type: ValidationErrorType.contextInconsistency, stepId: stepId);
