import 'dart:convert';

import 'workflow_definition.dart' show OutputConfig, OutputFormat, OutputMode, WorkflowStep;
import 'package:logging/logging.dart';

import 'context_output_defaults.dart';
import 'json_extraction.dart';
import 'review_finding_derivations.dart' as rfd;
import 'schema_presets.dart';
import 'schema_validator.dart';

final _log = Logger('ContextExtractor');

/// Validates [parsed] against any schema declared on [config].
///
/// Throws [FormatException] when the output key requires strict schema
/// conformance and validation fails. Logs warnings for soft violations.
void validateSchema(
  Object? parsed,
  OutputConfig config,
  SchemaValidator schemaValidator,
  String stepId,
  String outputKey,
) {
  if (parsed == null) return;

  Map<String, dynamic>? schema;
  if (config.presetName != null) {
    schema = schemaPresets[config.presetName]?.schema;
  } else if (config.inlineSchema != null) {
    schema = config.inlineSchema;
  }
  if (schema == null) return;

  final warnings = schemaValidator.validate(parsed, schema);
  if (warnings.isNotEmpty && requiresStrictSchema(config, outputKey)) {
    throw FormatException(
      'Structured output "$outputKey" from step "$stepId" failed schema validation: ${warnings.join('; ')}',
    );
  }
  for (final w in warnings) {
    _log.warning('Schema validation for "$outputKey" in step "$stepId": $w');
  }
}

/// Returns true when schema validation failures should be fatal for [outputKey].
bool requiresStrictSchema(OutputConfig config, String outputKey) {
  if (config.outputMode != OutputMode.structured) return false;
  return config.presetName == 'non_negative_integer' ||
      outputKey.endsWith('.findings_count') ||
      outputKey.endsWith('.gating_findings_count') ||
      outputKey == 'findings_count' ||
      outputKey == 'gating_findings_count';
}

/// Normalizes a raw payload value according to the declared output format.
Object? normalizePayloadValue(
  Object? payloadValue,
  OutputConfig? config,
  SchemaValidator schemaValidator,
  String stepId,
  String outputKey,
) {
  if (config == null || config.format == OutputFormat.text) {
    return stringifyWorkflowValue(payloadValue);
  }
  switch (config.format) {
    case OutputFormat.json:
      validateSchema(payloadValue, config, schemaValidator, stepId, outputKey);
      return payloadValue;
    case OutputFormat.lines:
      return switch (payloadValue) {
        final List<dynamic> values => values.map((v) => v.toString().trim()).where((s) => s.isNotEmpty).toList(),
        _ => extractLines(stringifyWorkflowValue(payloadValue)),
      };
    case OutputFormat.text:
    case OutputFormat.path:
      return stringifyWorkflowValue(payloadValue);
  }
}

/// Coerces a workflow value to a string, JSON-encoding non-strings.
String stringifyWorkflowValue(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return jsonEncode(value);
}

/// Derives a context output value from structured output payloads.
///
/// Priority: already-extracted value → review finding count → unscoped key → default.
dynamic deriveFromStructuredOutputs(
  WorkflowStep step,
  Map<String, dynamic> outputs,
  String outputKey, {
  required Map<String, dynamic>? workflowContextPayload,
  required Map<String, dynamic> structuredOutputPayload,
}) {
  if (outputs.containsKey(outputKey)) return outputs[outputKey];
  final reviewCount = rfd.deriveReviewFindingCount(outputKey, outputs, workflowContextPayload, structuredOutputPayload);
  if (reviewCount != null) return reviewCount;

  final lastDot = outputKey.lastIndexOf('.');
  if (lastDot > 0) {
    final unscopedKey = outputKey.substring(lastDot + 1);
    if (outputs.containsKey(unscopedKey)) return outputs[unscopedKey];
  }

  for (final value in outputs.values) {
    if (value is Map && value.containsKey(outputKey)) return value[outputKey];
  }
  return defaultContextOutput(step, outputs, outputKey);
}
