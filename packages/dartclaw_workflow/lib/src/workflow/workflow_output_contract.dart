/// Shared constants and helpers for the `<workflow-context>` output protocol.
///
/// The agent-facing prompt (see [PromptAugmenter]) and the server-side parser
/// (see [ContextExtractor]) must agree on the exact tag spelling. Both sides
/// import from this file to avoid silent drift.
library;

import 'dart:convert';

/// Tag name used to delimit the workflow-context JSON payload.
const String kWorkflowContextTag = 'workflow-context';

const String kWorkflowContextOpen = '<$kWorkflowContextTag>';

const String kWorkflowContextClose = '</$kWorkflowContextTag>';

/// Matches the `<workflow-context>...</workflow-context>` block and captures
/// its inner JSON payload in group 1.
final RegExp workflowContextRegExp = RegExp('$kWorkflowContextOpen\\s*([\\s\\S]*?)\\s*$kWorkflowContextClose');

/// Tag name used to delimit step outcome metadata in the final assistant message.
const String kStepOutcomeTag = 'step-outcome';

const String kStepOutcomeOpen = '<$kStepOutcomeTag>';

const String kStepOutcomeClose = '</$kStepOutcomeTag>';

/// Matches the `<step-outcome>...</step-outcome>` block and captures its inner
/// JSON payload in group 1.
final RegExp stepOutcomeRegExp = RegExp('$kStepOutcomeOpen\\s*([\\s\\S]*?)\\s*$kStepOutcomeClose');

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
      continue;
    }
  }
  return null;
}
