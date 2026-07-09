/// Shared constants and helpers for the `<workflow-context>` output protocol.
///
/// The agent-facing prompt (see [PromptAugmenter]) and the server-side parser
/// (see [ContextExtractor]) must agree on the exact tag spelling. Both sides
/// import from this file to avoid silent drift.
library;

import 'dart:convert';

/// Tag name used to delimit the workflow-context JSON payload.
const String workflowContextTag = 'workflow-context';

const String workflowContextOpen = '<$workflowContextTag>';

const String workflowContextClose = '</$workflowContextTag>';

/// Matches the `<workflow-context>...</workflow-context>` block and captures
/// its inner JSON payload in group 1.
final RegExp workflowContextRegExp = RegExp('$workflowContextOpen\\s*([\\s\\S]*?)\\s*$workflowContextClose');

/// Top-level key carrying declared domain outputs in the structured execution
/// envelope. Reserved as a declared-output key name (see the output-schema
/// validation rules) so a step cannot collide with the envelope shape.
const String executionEnvelopeOutputsKey = 'outputs';

/// Top-level key carrying engine-owned semantic step outcome in the execution
/// envelope. Reserved as a declared-output key name.
const String executionEnvelopeStepOutcomeKey = 'step_outcome';

/// Reserved declared-output key names that would collide with the execution
/// envelope's top-level shape.
const Set<String> reservedEnvelopeOutputKeys = {executionEnvelopeOutputsKey, executionEnvelopeStepOutcomeKey};

/// Host-stamped marker key recording the execution-envelope schema version on a
/// persisted `structuredOutput` payload.
///
/// The host injects this after receiving the finalizer envelope so envelope and
/// legacy flat payloads are discriminated deterministically — never by
/// shape-sniffing top-level keys, which stay stable across pre-upgrade rows and
/// resumed mid-run tasks. Absent from the strict schema sent to the provider.
const String executionEnvelopeMarkerKey = '_envelopeVersion';

/// Current execution-envelope schema version.
const int executionEnvelopeVersion = 1;

/// Whether [payload] is a host-stamped execution envelope (marker-discriminated,
/// never shape-sniffed).
bool isExecutionEnvelope(Map<String, dynamic>? payload) =>
    payload != null && payload[executionEnvelopeMarkerKey] is int;

/// Whether [schema] is the strict execution-envelope schema (top-level `outputs`
/// object), as opposed to a legacy flat structured-output schema.
///
/// The reserved key names are validator-forbidden as declared-output names
/// (see the output-schema rules), so a legacy flat schema can never carry a
/// top-level `outputs` property that is not the envelope.
bool isExecutionEnvelopeSchema(Map<String, dynamic>? schema) {
  final properties = schema?['properties'];
  return properties is Map && properties.containsKey(executionEnvelopeOutputsKey);
}

/// The declared domain-output keys carried under an execution-envelope
/// [schema]'s `outputs` object, in declaration order. Returns empty for a
/// non-envelope schema.
List<String> executionEnvelopeDeclaredOutputKeys(Map<String, dynamic>? schema) {
  final properties = schema?['properties'];
  if (properties is! Map) return const <String>[];
  final outputs = properties[executionEnvelopeOutputsKey];
  if (outputs is! Map) return const <String>[];
  final outputProperties = outputs['properties'];
  if (outputProperties is! Map) return const <String>[];
  return outputProperties.keys.map((key) => key.toString()).toList(growable: false);
}

/// Tag name used to delimit step outcome metadata in the final assistant message.
const String stepOutcomeTag = 'step-outcome';

const String stepOutcomeOpen = '<$stepOutcomeTag>';

const String stepOutcomeClose = '</$stepOutcomeTag>';

/// Matches the `<step-outcome>...</step-outcome>` block and captures its inner
/// JSON payload in group 1.
final RegExp stepOutcomeRegExp = RegExp('$stepOutcomeOpen\\s*([\\s\\S]*?)\\s*$stepOutcomeClose');

class StepOutcomePayload {
  final String outcome;
  final String reason;

  const StepOutcomePayload({required this.outcome, required this.reason});
}

/// Parses the last well-formed `<step-outcome>` payload from [message].
///
/// Returns null when the tag is absent, malformed, or contains an outcome
/// outside the supported protocol values.
StepOutcomePayload? parseStepOutcomePayload(String message) {
  final matches = stepOutcomeRegExp.allMatches(message).toList(growable: false);
  for (final match in matches.reversed) {
    final rawJson = match.group(1);
    if (rawJson == null) continue;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) continue;
      final outcome = decoded['outcome']?.toString();
      if (outcome != 'succeeded' && outcome != 'failed' && outcome != 'needsInput') {
        continue;
      }
      final reason = decoded['reason']?.toString() ?? '';
      return StepOutcomePayload(outcome: outcome!, reason: reason);
    } catch (_) {
      continue; // Malformed step-outcome JSON line — skip and try the next candidate.
    }
  }
  return null;
}
